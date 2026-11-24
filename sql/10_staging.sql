-- Kino BI · Woche 11 · 10_staging: Rohdaten typisiert, ohne Zeilen zu verlieren oder zu erfinden.
-- Regel: kino_raw bleibt unverändert (alles Text). Jede Typumwandlung passiert hier, sichtbar.
-- Jede View führt cast_errors mit: Anzahl Felder, die im Rohwert gefüllt sind, aber nicht
-- umgewandelt werden konnten. Die Pipeline prüft, dass die Summe 0 ist (Regel Q02).

-- Alle Datasets liegen in Zürich; ohne diese Zeile führt BigQuery das Skript in US aus.
SET @@location = 'europe-west6';

-- Ganzzahl aus Text. "540.0" wird 540, "540.5" wird NULL (und zählt als Umwandlungsfehler),
-- damit nie stillschweigend gerundet wird.
CREATE OR REPLACE FUNCTION `daeng-spengmik-y5go.kino_stg.to_int`(s STRING) AS (
  IF(MOD(SAFE_CAST(TRIM(s) AS NUMERIC), 1) = 0, CAST(SAFE_CAST(TRIM(s) AS NUMERIC) AS INT64), NULL)
);

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_produkte` AS
SELECT
  produkt_id AS product_id,
  name AS product_name,
  produktgruppe AS product_group,
  `daeng-spengmik-y5go.kino_stg.to_int`(haltbarkeit_tage) AS shelf_life_days,
  SAFE_CAST(einkaufspreis_chf AS NUMERIC) AS purchase_price_chf,
  SAFE_CAST(verkaufspreis_chf AS NUMERIC) AS selling_price_chf,
  (IF(haltbarkeit_tage IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(haltbarkeit_tage) IS NULL, 1, 0)
 + IF(einkaufspreis_chf IS NOT NULL AND SAFE_CAST(einkaufspreis_chf AS NUMERIC) IS NULL, 1, 0)
 + IF(verkaufspreis_chf IS NOT NULL AND SAFE_CAST(verkaufspreis_chf AS NUMERIC) IS NULL, 1, 0)) AS cast_errors
FROM `daeng-spengmik-y5go.kino_raw.produkte`;

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_saele` AS
SELECT
  saal_id AS auditorium_id,
  `daeng-spengmik-y5go.kino_stg.to_int`(kapazitaet) AS capacity,
  IF(kapazitaet IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(kapazitaet) IS NULL, 1, 0) AS cast_errors
FROM `daeng-spengmik-y5go.kino_raw.saele`;

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_filme` AS
SELECT
  film_id,
  titel AS title,
  SAFE.PARSE_DATE('%Y-%m-%d', startdatum) AS release_date,
  -- Blockbuster ist laut Dateninventar eine Einschätzung des Verleihers, kodiert als 1/0.
  CASE blockbuster WHEN '1' THEN TRUE WHEN '0' THEN FALSE END AS is_blockbuster,
  (IF(startdatum IS NOT NULL AND SAFE.PARSE_DATE('%Y-%m-%d', startdatum) IS NULL, 1, 0)
 + IF(blockbuster IS NOT NULL AND blockbuster NOT IN ('0', '1'), 1, 0)) AS cast_errors
FROM `daeng-spengmik-y5go.kino_raw.filme_startkalender`;

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_vorstellungen` AS
SELECT
  vorstellung_id AS screening_id,
  SAFE.PARSE_DATE('%Y-%m-%d', datum) AS screening_date,
  beginn AS start_time_local,
  saal_id AS auditorium_id,
  film_id,
  `daeng-spengmik-y5go.kino_stg.to_int`(tickets_verkauft) AS tickets_sold,
  `daeng-spengmik-y5go.kino_stg.to_int`(davon_online_reserviert) AS online_reservations,
  -- Kapazität so, wie das Ticketing sie zum Zeitpunkt der Vorstellung meldet (nicht aus der Saalliste).
  `daeng-spengmik-y5go.kino_stg.to_int`(kapazitaet) AS capacity_at_screening,
  (IF(datum IS NOT NULL AND SAFE.PARSE_DATE('%Y-%m-%d', datum) IS NULL, 1, 0)
 + IF(beginn IS NOT NULL AND SAFE.PARSE_TIME('%H:%M', beginn) IS NULL, 1, 0)
 + IF(tickets_verkauft IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(tickets_verkauft) IS NULL, 1, 0)
 + IF(davon_online_reserviert IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(davon_online_reserviert) IS NULL, 1, 0)
 + IF(kapazitaet IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(kapazitaet) IS NULL, 1, 0)) AS cast_errors
FROM `daeng-spengmik-y5go.kino_raw.ticketing_vorstellungen`;

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_pos` AS
WITH numbered AS (
  SELECT r.*,
    -- Die Kasse liefert keine Positionsnummer (PR-02). Vollständig identische Zeilen sind nicht
    -- unterscheidbar; wir nummerieren sie innerhalb der Gruppe. Die erste zählt als Original,
    -- jede weitere als identische Wiederholung. Welche "die erste" ist, spielt keine Rolle,
    -- weil alle Felder gleich sind.
    ROW_NUMBER() OVER (PARTITION BY beleg_id, zeitstempel, produkt_id, menge, betrag_chf
                       ORDER BY beleg_id) AS occurrence_no
  FROM `daeng-spengmik-y5go.kino_raw.kiosk_pos_positionen` r
)
SELECT
  -- Schlüssel aus dem Inhalt plus Nummer in der Gruppe: bleibt gleich, wenn dieselbe Datei
  -- in anderer Reihenfolge neu geladen wird (die alte Version hing an der Zeilennummer der Datei).
  TO_HEX(SHA256(TO_JSON_STRING(STRUCT(beleg_id, zeitstempel, produkt_id, menge, betrag_chf,
                                      occurrence_no)))) AS sales_line_key,
  beleg_id AS receipt_id,
  SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', zeitstempel) AS sold_at_local,
  produkt_id AS source_product_id,
  `daeng-spengmik-y5go.kino_stg.to_int`(menge) AS units,
  SAFE_CAST(betrag_chf AS NUMERIC) AS amount_chf,
  occurrence_no,
  (IF(zeitstempel IS NOT NULL AND SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', zeitstempel) IS NULL, 1, 0)
 + IF(menge IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(menge) IS NULL, 1, 0)
 + IF(betrag_chf IS NOT NULL AND SAFE_CAST(betrag_chf AS NUMERIC) IS NULL, 1, 0)) AS cast_errors
FROM numbered;

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_bestand` AS
SELECT
  produkt_id AS product_id,
  `daeng-spengmik-y5go.kino_stg.to_int`(bestand) AS book_units,
  SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', letzte_aenderung) AS last_changed_at_local,
  (IF(bestand IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(bestand) IS NULL, 1, 0)
 + IF(letzte_aenderung IS NOT NULL AND SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', letzte_aenderung) IS NULL, 1, 0)) AS cast_errors
FROM `daeng-spengmik-y5go.kino_raw.lager_bestand_aktuell`;

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_inventur` AS
SELECT
  SAFE.PARSE_DATE('%Y-%m-%d', datum) AS count_date,
  produkt_id AS product_id,
  `daeng-spengmik-y5go.kino_stg.to_int`(bestand_verbucht) AS book_units,
  -- Leer heisst laut Data Dictionary "nicht gezählt", nicht 0. Bleibt NULL.
  `daeng-spengmik-y5go.kino_stg.to_int`(bestand_gezaehlt) AS counted_units,
  gezaehlt_von AS counted_by,
  (IF(datum IS NOT NULL AND SAFE.PARSE_DATE('%Y-%m-%d', datum) IS NULL, 1, 0)
 + IF(bestand_verbucht IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(bestand_verbucht) IS NULL, 1, 0)
 + IF(bestand_gezaehlt IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(bestand_gezaehlt) IS NULL, 1, 0)) AS cast_errors
FROM `daeng-spengmik-y5go.kino_raw.lager_inventur_woechentlich`;

CREATE OR REPLACE VIEW `daeng-spengmik-y5go.kino_stg.stg_bestellungen` AS
SELECT
  bestell_id AS order_id,
  lieferant AS supplier_name,
  produkt_id AS product_id,
  SAFE.PARSE_DATE('%Y-%m-%d', bestelldatum) AS order_date,
  `daeng-spengmik-y5go.kino_stg.to_int`(bestellmenge) AS ordered_units,
  -- Leeres Lieferdatum heisst laut Data Dictionary "nicht übertragen", nicht "nicht geliefert".
  SAFE.PARSE_DATE('%Y-%m-%d', lieferdatum) AS delivery_date,
  `daeng-spengmik-y5go.kino_stg.to_int`(liefermenge) AS delivered_units,
  (IF(bestelldatum IS NOT NULL AND SAFE.PARSE_DATE('%Y-%m-%d', bestelldatum) IS NULL, 1, 0)
 + IF(bestellmenge IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(bestellmenge) IS NULL, 1, 0)
 + IF(lieferdatum IS NOT NULL AND SAFE.PARSE_DATE('%Y-%m-%d', lieferdatum) IS NULL, 1, 0)
 + IF(liefermenge IS NOT NULL AND `daeng-spengmik-y5go.kino_stg.to_int`(liefermenge) IS NULL, 1, 0)) AS cast_errors
FROM `daeng-spengmik-y5go.kino_raw.bestellungen_lieferungen`;
