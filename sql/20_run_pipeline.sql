-- Kino BI · Woche 11 · 20_run_pipeline: die ganze Kette in einem Aufruf.
--
--   CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(FALSE, FALSE);  -- bauen und prüfen, kino_star bleibt
--   CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(TRUE,  FALSE);  -- bauen, prüfen, bei Erfolg veröffentlichen
--   CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(TRUE,  TRUE);   -- Test der Schranke: eine Pflichtregel scheitert absichtlich
--
-- Ablauf: 1. Sternschema und Würfel in kino_build bauen (aus kino_stg, also aus kino_raw)
--         2. Prüfregeln ausführen, Ergebnis pro Regel nach kino_ops.dq_results
--         3. Schranke: nur wenn keine PFLICHT-Regel scheitert, wird kino_build nach kino_star kopiert
--         4. Eintrag im Laufprotokoll kino_ops.pipeline_runs
-- Wiederholbar: jede Tabelle wird vollständig ersetzt (kein Anhängen), ein zweiter Lauf auf
-- denselben Rohdaten ergibt dieselben Tabellen.

-- Alle Datasets liegen in Zürich; ohne diese Zeile führt BigQuery das Skript in US aus.
SET @@location = 'europe-west6';

CREATE OR REPLACE PROCEDURE `daeng-spengmik-y5go.kino_ops.run_pipeline`(p_publish BOOL, p_test_fail BOOL)
OPTIONS (description = 'Kino-Pipeline: kino_raw -> kino_stg -> kino_build -> Prüfungen -> (Schranke) -> kino_star. Woche 11, Team Data-Miners. Simulierte Daten.')
BEGIN
  DECLARE v_run_id STRING DEFAULT GENERATE_UUID();
  DECLARE v_started TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE v_failed_mandatory INT64 DEFAULT 0;
  DECLARE v_warnings INT64 DEFAULT 0;
  DECLARE v_counts JSON;
  DECLARE v_published BOOL DEFAULT FALSE;

  BEGIN
    -- ===== 1. Bauen ========================================================================

    -- Kalender über alle Datumsangaben aller Quellen, ohne Lücken.
    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.dim_date`
    OPTIONS (description = 'Kalender von frühestem bis spätestem Datum aller Quellen. Gebaut von kino_ops.run_pipeline.') AS
    WITH all_dates AS (
      SELECT release_date AS d FROM `daeng-spengmik-y5go.kino_stg.stg_filme`
      UNION ALL SELECT screening_date FROM `daeng-spengmik-y5go.kino_stg.stg_vorstellungen`
      UNION ALL SELECT DATE(sold_at_local) FROM `daeng-spengmik-y5go.kino_stg.stg_pos`
      UNION ALL SELECT count_date FROM `daeng-spengmik-y5go.kino_stg.stg_inventur`
      UNION ALL SELECT order_date FROM `daeng-spengmik-y5go.kino_stg.stg_bestellungen`
      UNION ALL SELECT delivery_date FROM `daeng-spengmik-y5go.kino_stg.stg_bestellungen`
      UNION ALL SELECT DATE(last_changed_at_local) FROM `daeng-spengmik-y5go.kino_stg.stg_bestand`
    )
    SELECT CAST(FORMAT_DATE('%Y%m%d', d) AS INT64) AS date_key,
      d AS calendar_date,
      EXTRACT(YEAR FROM d) AS year,
      EXTRACT(MONTH FROM d) AS month,
      EXTRACT(ISOWEEK FROM d) AS iso_week,
      MOD(EXTRACT(DAYOFWEEK FROM d) + 5, 7) + 1 AS weekday_iso,   -- Montag = 1 ... Sonntag = 7
      EXTRACT(DAYOFWEEK FROM d) IN (1, 7) AS is_weekend
    FROM UNNEST(GENERATE_DATE_ARRAY((SELECT MIN(d) FROM all_dates), (SELECT MAX(d) FROM all_dates))) AS d;

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.dim_product`
    OPTIONS (description = 'Artikelstamm plus ein Eintrag __UNKNOWN__ für Kassenartikel ohne Stammdaten (PR-04).') AS
    SELECT product_id AS product_key, product_name, product_group, shelf_life_days,
      purchase_price_chf, selling_price_chf,
      -- Projektentscheid: Popcorn (frisch, verdirbt am selben Tag) ist nicht im Nachbestell-Modell.
      product_group != 'Popcorn' AS in_replenishment_scope,
      FALSE AS is_unknown
    FROM `daeng-spengmik-y5go.kino_stg.stg_produkte`
    UNION ALL
    SELECT '__UNKNOWN__', 'Unknown product', 'Unknown', NULL, NULL, NULL, FALSE, TRUE;

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.dim_auditorium`
    OPTIONS (description = 'Säle mit Sitzplätzen laut Saalliste.') AS
    SELECT auditorium_id AS auditorium_key, capacity FROM `daeng-spengmik-y5go.kino_stg.stg_saele`;

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.dim_film`
    OPTIONS (description = 'Filme laut Startkalender des Verleihers.') AS
    SELECT film_id AS film_key, title, release_date, is_blockbuster FROM `daeng-spengmik-y5go.kino_stg.stg_filme`;

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.dim_supplier`
    OPTIONS (description = 'Lieferanten aus den Bestellungen; Schlüssel = SHA-256 des Namens.') AS
    SELECT DISTINCT TO_HEX(SHA256(supplier_name)) AS supplier_key, supplier_name
    FROM `daeng-spengmik-y5go.kino_stg.stg_bestellungen` WHERE supplier_name IS NOT NULL;

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.fact_sales`
    OPTIONS (description = 'Eine Zeile pro Kassenposition. Verkäufe, nicht Nachfrage (Ausverkauf ist nicht sichtbar).') AS
    SELECT s.sales_line_key,
      CAST(FORMAT_DATE('%Y%m%d', DATE(s.sold_at_local)) AS INT64) AS date_key,
      IF(p.product_id IS NULL, '__UNKNOWN__', s.source_product_id) AS product_key,
      s.source_product_id, s.receipt_id, s.sold_at_local, s.units, s.amount_chf,
      s.units < 0 AS is_cancellation,
      s.occurrence_no > 1 AS is_identical_repeat,
      s.occurrence_no
    FROM `daeng-spengmik-y5go.kino_stg.stg_pos` s
    LEFT JOIN `daeng-spengmik-y5go.kino_stg.stg_produkte` p ON p.product_id = s.source_product_id;

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.fact_screening`
    OPTIONS (description = 'Eine Zeile pro Vorstellung mit verkauften Tickets.') AS
    SELECT screening_id AS screening_key,
      CAST(FORMAT_DATE('%Y%m%d', screening_date) AS INT64) AS date_key,
      film_id AS film_key, auditorium_id AS auditorium_key, start_time_local,
      tickets_sold, online_reservations, capacity_at_screening,
      tickets_sold > capacity_at_screening AS is_over_capacity,
      COUNT(*) OVER (PARTITION BY auditorium_id, screening_date, start_time_local) > 1 AS is_same_start_conflict
    FROM `daeng-spengmik-y5go.kino_stg.stg_vorstellungen`;

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.fact_inventory_count`
    OPTIONS (description = 'Wöchentliche Inventur: verbucht vs. gezählt. Nicht gezählt bleibt NULL, nicht 0.') AS
    SELECT CONCAT(CAST(i.count_date AS STRING), ':', i.product_id) AS inventory_count_key,
      CAST(FORMAT_DATE('%Y%m%d', i.count_date) AS INT64) AS date_key,
      IF(p.product_id IS NULL, '__UNKNOWN__', i.product_id) AS product_key,
      i.book_units, i.counted_units,
      i.counted_units - i.book_units AS variance_units,
      IF(i.counted_units IS NULL, 'NOT_COUNTED', 'COUNTED') AS count_status
    FROM `daeng-spengmik-y5go.kino_stg.stg_inventur` i
    LEFT JOIN `daeng-spengmik-y5go.kino_stg.stg_produkte` p USING (product_id);

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot`
    OPTIONS (description = 'Aktueller Buchbestand. Die Quelle überschreibt ihn, es gibt keine Historie (PR-13).') AS
    SELECT CONCAT(b.product_id, ':', FORMAT_DATETIME('%Y-%m-%d %H:%M:%S', b.last_changed_at_local)) AS snapshot_key,
      CAST(FORMAT_DATE('%Y%m%d', DATE(b.last_changed_at_local)) AS INT64) AS date_key,
      IF(p.product_id IS NULL, '__UNKNOWN__', b.product_id) AS product_key,
      b.last_changed_at_local, b.book_units
    FROM `daeng-spengmik-y5go.kino_stg.stg_bestand` b
    LEFT JOIN `daeng-spengmik-y5go.kino_stg.stg_produkte` p USING (product_id);

    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.fact_order_delivery`
    OPTIONS (description = 'Eine Zeile pro Bestellung mit Wareneingang. Fehlendes Lieferdatum = nicht übertragen.') AS
    SELECT TO_HEX(SHA256(CONCAT('bestellungen_lieferungen|', o.order_id))) AS order_line_key,
      o.order_id,
      IF(p.product_id IS NULL, '__UNKNOWN__', o.product_id) AS product_key,
      TO_HEX(SHA256(o.supplier_name)) AS supplier_key,
      CAST(FORMAT_DATE('%Y%m%d', o.order_date) AS INT64) AS order_date_key,
      CAST(FORMAT_DATE('%Y%m%d', o.delivery_date) AS INT64) AS delivery_date_key,
      o.ordered_units, o.delivered_units,
      DATE_DIFF(o.delivery_date, o.order_date, DAY) AS lead_time_days,
      IF(o.delivery_date IS NULL OR o.delivered_units IS NULL, 'INCOMPLETE_RECORD', 'RECORDED') AS delivery_status,
      o.delivered_units < o.ordered_units AS is_partial_delivery,
      DATE_DIFF(o.delivery_date, o.order_date, DAY) <= 0 AS is_nonpositive_lead_time
    FROM `daeng-spengmik-y5go.kino_stg.stg_bestellungen` o
    LEFT JOIN `daeng-spengmik-y5go.kino_stg.stg_produkte` p USING (product_id);

    -- OLAP-Würfel aus Woche 9, jetzt Teil der Kette statt manueller Snapshot.
    CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_build.cube_sales_monthly`
    OPTIONS (
      description = 'Relationaler OLAP-Würfel Monat x Produktgruppe x Produkt. Wird bei jedem Lauf von kino_ops.run_pipeline neu gebaut. Vor dem Summieren auf aggregation_level filtern.',
      labels = [('managed_by', 'kino_pipeline'), ('is_synthetic', 'true')]
    ) AS
    WITH base AS (
      SELECT DATE_TRUNC(d.calendar_date, MONTH) AS sales_month,
        p.product_group, p.product_key, p.in_replenishment_scope, f.units, f.amount_chf
      FROM `daeng-spengmik-y5go.kino_build.fact_sales` f
      JOIN `daeng-spengmik-y5go.kino_build.dim_date` d USING (date_key)
      JOIN `daeng-spengmik-y5go.kino_build.dim_product` p USING (product_key)
    )
    SELECT sales_month, product_group, product_key,
      GROUPING(sales_month) = 1 AS is_all_months,
      GROUPING(product_group) = 1 AS is_all_groups,
      GROUPING(product_key) = 1 AS is_all_products,
      GROUPING(sales_month) * 4 + GROUPING(product_group) * 2 + GROUPING(product_key) AS aggregation_level,
      COUNT(*) AS source_lines,
      SUM(units) AS net_units,
      SUM(amount_chf) AS net_revenue_chf,
      SUM(IF(in_replenishment_scope, units, 0)) AS scope_net_units,
      SUM(IF(in_replenishment_scope, amount_chf, NUMERIC '0')) AS scope_net_revenue_chf,
      TRUE AS is_synthetic,
      CURRENT_TIMESTAMP() AS built_at
    FROM base
    GROUP BY CUBE (sales_month, product_group, product_key);

    SET v_counts = TO_JSON(STRUCT(
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.dim_date`) AS dim_date,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.dim_product`) AS dim_product,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.dim_auditorium`) AS dim_auditorium,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.dim_film`) AS dim_film,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.dim_supplier`) AS dim_supplier,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_sales`) AS fact_sales,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_screening`) AS fact_screening,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count`) AS fact_inventory_count,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot`) AS fact_inventory_snapshot,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery`) AS fact_order_delivery,
      (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly`) AS cube_sales_monthly));

    -- ===== 2. Prüfen ======================================================================
    -- Jede Regel liefert die Anzahl Verstösse (observed). Bestanden heisst observed = 0.
    -- Keine fest eingetragenen Zeilenzahlen: die Regeln gelten auch für neue Lieferungen.
    INSERT INTO `daeng-spengmik-y5go.kino_ops.dq_results`
      (run_id, checked_at, rule_id, severity, area, description, profiling_ref, observed, expected, passed)
    SELECT v_run_id, CURRENT_TIMESTAMP(), rule_id, severity, area, description, profiling_ref,
      observed, '0', observed = 0
    FROM (
      -- Q01 Rohdaten vorhanden: ein leerer Export darf nie ein volles Sternschema ersetzen.
      SELECT 'Q01' AS rule_id, 'PFLICHT' AS severity, 'Vollständigkeit' AS area,
        'Jede der 8 Rohtabellen hat mindestens eine Zeile (Anzahl leerer Tabellen)' AS description,
        CAST(NULL AS STRING) AS profiling_ref,
        (SELECT COUNTIF(row_count = 0) + 8 - COUNT(*) FROM `daeng-spengmik-y5go.kino_raw.__TABLES__`) AS observed
      -- Q02 Typumwandlung verlustfrei: kein gefüllter Rohwert wird beim Umwandeln stillschweigend leer.
      UNION ALL SELECT 'Q02', 'PFLICHT', 'Wertebereich',
        'Kein gefüllter Rohwert geht bei der Typumwandlung verloren (Summe cast_errors in kino_stg)', NULL,
        (SELECT SUM(e) FROM (
          SELECT SUM(cast_errors) e FROM `daeng-spengmik-y5go.kino_stg.stg_produkte`
          UNION ALL SELECT SUM(cast_errors) FROM `daeng-spengmik-y5go.kino_stg.stg_saele`
          UNION ALL SELECT SUM(cast_errors) FROM `daeng-spengmik-y5go.kino_stg.stg_filme`
          UNION ALL SELECT SUM(cast_errors) FROM `daeng-spengmik-y5go.kino_stg.stg_vorstellungen`
          UNION ALL SELECT SUM(cast_errors) FROM `daeng-spengmik-y5go.kino_stg.stg_pos`
          UNION ALL SELECT SUM(cast_errors) FROM `daeng-spengmik-y5go.kino_stg.stg_bestand`
          UNION ALL SELECT SUM(cast_errors) FROM `daeng-spengmik-y5go.kino_stg.stg_inventur`
          UNION ALL SELECT SUM(cast_errors) FROM `daeng-spengmik-y5go.kino_stg.stg_bestellungen`))
      -- Q03 Schlüssel eindeutig und gefüllt (Duplikate + leere Schlüssel).
      UNION ALL SELECT 'Q03-dim_date', 'PFLICHT', 'Eindeutigkeit', 'dim_date.date_key eindeutig und gefüllt', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT date_key) + COUNTIF(date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.dim_date`)
      UNION ALL SELECT 'Q03-dim_product', 'PFLICHT', 'Eindeutigkeit', 'dim_product.product_key eindeutig und gefüllt', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT product_key) + COUNTIF(product_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.dim_product`)
      UNION ALL SELECT 'Q03-dim_auditorium', 'PFLICHT', 'Eindeutigkeit', 'dim_auditorium.auditorium_key eindeutig und gefüllt', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT auditorium_key) + COUNTIF(auditorium_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.dim_auditorium`)
      UNION ALL SELECT 'Q03-dim_film', 'PFLICHT', 'Eindeutigkeit', 'dim_film.film_key eindeutig und gefüllt', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT film_key) + COUNTIF(film_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.dim_film`)
      UNION ALL SELECT 'Q03-dim_supplier', 'PFLICHT', 'Eindeutigkeit', 'dim_supplier.supplier_key eindeutig und gefüllt', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT supplier_key) + COUNTIF(supplier_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.dim_supplier`)
      UNION ALL SELECT 'Q03-fact_sales', 'PFLICHT', 'Eindeutigkeit', 'fact_sales.sales_line_key eindeutig und gefüllt', 'PR-02',
        (SELECT COUNT(*) - COUNT(DISTINCT sales_line_key) + COUNTIF(sales_line_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)
      UNION ALL SELECT 'Q03-fact_screening', 'PFLICHT', 'Eindeutigkeit', 'fact_screening.screening_key eindeutig und gefüllt', 'PR-08',
        (SELECT COUNT(*) - COUNT(DISTINCT screening_key) + COUNTIF(screening_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_screening`)
      UNION ALL SELECT 'Q03-fact_inventory_count', 'PFLICHT', 'Eindeutigkeit', 'fact_inventory_count: ein Eintrag pro Zähltag und Produkt', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT inventory_count_key) + COUNTIF(inventory_count_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count`)
      UNION ALL SELECT 'Q03-fact_inventory_snapshot', 'PFLICHT', 'Eindeutigkeit', 'fact_inventory_snapshot.snapshot_key eindeutig und gefüllt', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT snapshot_key) + COUNTIF(snapshot_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot`)
      UNION ALL SELECT 'Q03-fact_order_delivery', 'PFLICHT', 'Eindeutigkeit', 'fact_order_delivery: eine Zeile pro bestell_id', NULL,
        (SELECT COUNT(*) - COUNT(DISTINCT order_line_key) + COUNTIF(order_line_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery`)
      -- Q04 Beziehungen: jeder gefüllte Fremdschlüssel findet seine Dimension.
      UNION ALL SELECT 'Q04-sales-date', 'PFLICHT', 'Beziehungen', 'fact_sales.date_key -> dim_date', NULL,
        (SELECT COUNTIF(f.date_key IS NOT NULL AND d.date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_sales` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_date` d USING (date_key))
      UNION ALL SELECT 'Q04-sales-product', 'PFLICHT', 'Beziehungen', 'fact_sales.product_key -> dim_product', 'PR-04',
        (SELECT COUNTIF(f.product_key IS NOT NULL AND d.product_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_sales` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_product` d USING (product_key))
      UNION ALL SELECT 'Q04-screening-date', 'PFLICHT', 'Beziehungen', 'fact_screening.date_key -> dim_date', NULL,
        (SELECT COUNTIF(f.date_key IS NOT NULL AND d.date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_screening` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_date` d USING (date_key))
      UNION ALL SELECT 'Q04-screening-film', 'PFLICHT', 'Beziehungen', 'fact_screening.film_key -> dim_film', NULL,
        (SELECT COUNTIF(f.film_key IS NOT NULL AND d.film_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_screening` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_film` d USING (film_key))
      UNION ALL SELECT 'Q04-screening-auditorium', 'PFLICHT', 'Beziehungen', 'fact_screening.auditorium_key -> dim_auditorium', NULL,
        (SELECT COUNTIF(f.auditorium_key IS NOT NULL AND d.auditorium_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_screening` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_auditorium` d USING (auditorium_key))
      UNION ALL SELECT 'Q04-inventory-date', 'PFLICHT', 'Beziehungen', 'fact_inventory_count.date_key -> dim_date', NULL,
        (SELECT COUNTIF(f.date_key IS NOT NULL AND d.date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_date` d USING (date_key))
      UNION ALL SELECT 'Q04-inventory-product', 'PFLICHT', 'Beziehungen', 'fact_inventory_count.product_key -> dim_product', NULL,
        (SELECT COUNTIF(f.product_key IS NOT NULL AND d.product_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_product` d USING (product_key))
      UNION ALL SELECT 'Q04-snapshot-date', 'PFLICHT', 'Beziehungen', 'fact_inventory_snapshot.date_key -> dim_date', NULL,
        (SELECT COUNTIF(f.date_key IS NOT NULL AND d.date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_date` d USING (date_key))
      UNION ALL SELECT 'Q04-snapshot-product', 'PFLICHT', 'Beziehungen', 'fact_inventory_snapshot.product_key -> dim_product', NULL,
        (SELECT COUNTIF(f.product_key IS NOT NULL AND d.product_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_product` d USING (product_key))
      UNION ALL SELECT 'Q04-order-date', 'PFLICHT', 'Beziehungen', 'fact_order_delivery.order_date_key -> dim_date', NULL,
        (SELECT COUNTIF(f.order_date_key IS NOT NULL AND d.date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_date` d ON d.date_key = f.order_date_key)
      UNION ALL SELECT 'Q04-delivery-date', 'PFLICHT', 'Beziehungen', 'fact_order_delivery.delivery_date_key -> dim_date', NULL,
        (SELECT COUNTIF(f.delivery_date_key IS NOT NULL AND d.date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_date` d ON d.date_key = f.delivery_date_key)
      UNION ALL SELECT 'Q04-order-product', 'PFLICHT', 'Beziehungen', 'fact_order_delivery.product_key -> dim_product', NULL,
        (SELECT COUNTIF(f.product_key IS NOT NULL AND d.product_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_product` d USING (product_key))
      UNION ALL SELECT 'Q04-order-supplier', 'PFLICHT', 'Beziehungen', 'fact_order_delivery.supplier_key -> dim_supplier', NULL,
        (SELECT COUNTIF(f.supplier_key IS NOT NULL AND d.supplier_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery` f LEFT JOIN `daeng-spengmik-y5go.kino_build.dim_supplier` d USING (supplier_key))
      -- Q05 Abgleich: die Transformation verliert und erfindet keine Zeilen, Mengen oder Franken.
      UNION ALL SELECT 'Q05-rows', 'PFLICHT', 'Abgleich',
        'Zeilen roh = Zeilen Stern für alle 5 Faktentabellen (Summe der absoluten Differenzen)', NULL,
        ABS((SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_raw.kiosk_pos_positionen`) - (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_sales`))
        + ABS((SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_raw.ticketing_vorstellungen`) - (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_screening`))
        + ABS((SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_raw.lager_inventur_woechentlich`) - (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count`))
        + ABS((SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_raw.lager_bestand_aktuell`) - (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot`))
        + ABS((SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_raw.bestellungen_lieferungen`) - (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery`))
      UNION ALL SELECT 'Q05-units', 'PFLICHT', 'Abgleich', 'Summe Stück Kasse roh = fact_sales', NULL,
        CAST(ABS((SELECT SUM(CAST(menge AS NUMERIC)) FROM `daeng-spengmik-y5go.kino_raw.kiosk_pos_positionen`) - (SELECT SUM(units) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)) AS INT64)
      UNION ALL SELECT 'Q05-chf', 'PFLICHT', 'Abgleich', 'Summe CHF Kasse roh = fact_sales (Differenz in Rappen)', NULL,
        CAST(ROUND(100 * ABS((SELECT SUM(CAST(betrag_chf AS NUMERIC)) FROM `daeng-spengmik-y5go.kino_raw.kiosk_pos_positionen`) - (SELECT SUM(amount_chf) FROM `daeng-spengmik-y5go.kino_build.fact_sales`))) AS INT64)
      UNION ALL SELECT 'Q05-tickets', 'PFLICHT', 'Abgleich', 'Summe Tickets roh = fact_screening', NULL,
        ABS((SELECT SUM(CAST(tickets_verkauft AS INT64)) FROM `daeng-spengmik-y5go.kino_raw.ticketing_vorstellungen`) - (SELECT SUM(tickets_sold) FROM `daeng-spengmik-y5go.kino_build.fact_screening`))
      -- Q06 Fehlend bleibt fehlend: leere Felder werden nicht zu 0 (Data Dictionary, Null-Semantik).
      UNION ALL SELECT 'Q06-counts', 'PFLICHT', 'Vollständigkeit', 'Nicht gezählte Inventurzeilen bleiben NULL (roh = Stern)', 'PR-10',
        ABS((SELECT COUNTIF(counted_units IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count`) - (SELECT COUNTIF(bestand_gezaehlt IS NULL) FROM `daeng-spengmik-y5go.kino_raw.lager_inventur_woechentlich`))
      UNION ALL SELECT 'Q06-delivery', 'PFLICHT', 'Vollständigkeit', 'Fehlende Lieferdaten bleiben NULL (roh = Stern)', 'PR-14',
        ABS((SELECT COUNTIF(delivery_date_key IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery`) - (SELECT COUNTIF(lieferdatum IS NULL) FROM `daeng-spengmik-y5go.kino_raw.bestellungen_lieferungen`))
      -- Q07 Pflichtfelder der Fakten gefüllt.
      UNION ALL SELECT 'Q07', 'PFLICHT', 'Vollständigkeit', 'Datum, Menge und Betrag jeder Kassenposition sowie Datum und Tickets jeder Vorstellung gefüllt', 'PR-01',
        (SELECT COUNTIF(date_key IS NULL OR units IS NULL OR amount_chf IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)
        + (SELECT COUNTIF(date_key IS NULL OR tickets_sold IS NULL) FROM `daeng-spengmik-y5go.kino_build.fact_screening`)
      -- Q08 Würfel: jede der 8 Aggregationsstufen ist eine vollständige Sicht auf dieselben Verkäufe.
      UNION ALL SELECT 'Q08-levels', 'PFLICHT', 'Abgleich', 'Würfel hat genau 8 Aggregationsstufen und genau ein Gesamttotal', NULL,
        (SELECT ABS(COUNT(DISTINCT aggregation_level) - 8) + ABS(COUNTIF(aggregation_level = 7) - 1) FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly`)
      UNION ALL SELECT 'Q08-sums', 'PFLICHT', 'Abgleich', 'Jede Aggregationsstufe summiert auf dieselben Zeilen, Stück und Franken wie fact_sales (Anzahl abweichender Stufen)', NULL,
        (SELECT COUNT(*) FROM (
          SELECT aggregation_level FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly`
          GROUP BY aggregation_level
          HAVING SUM(source_lines) != (SELECT COUNT(*) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)
              OR SUM(net_units) != (SELECT SUM(units) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)
              OR SUM(net_revenue_chf) != (SELECT SUM(amount_chf) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)))
      UNION ALL SELECT 'Q08-cells', 'PFLICHT', 'Eindeutigkeit', 'Würfel: jede Zelle einmal pro Stufe, ALL-Kennzeichen konsistent', NULL,
        (SELECT COUNT(*) FROM (
          SELECT 1 FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly`
          GROUP BY sales_month, product_group, product_key, aggregation_level HAVING COUNT(*) > 1))
        + (SELECT COUNTIF(is_all_months != (sales_month IS NULL) OR is_all_groups != (product_group IS NULL)
                          OR is_all_products != (product_key IS NULL)
                          OR aggregation_level != IF(is_all_months, 4, 0) + IF(is_all_groups, 2, 0) + IF(is_all_products, 1, 0))
           FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly`)
      -- Q99 nur im Test der Schranke: eine Pflichtregel, die nicht bestehen kann.
      UNION ALL SELECT 'Q99-test', 'PFLICHT', 'Test', 'Absichtlich fehlschlagende Regel, um die Schranke zu prüfen (nur mit p_test_fail)', NULL, 1
      FROM UNNEST([1]) WHERE p_test_fail

      -- ===== Warnungen: bekannte Befunde aus dem Profiling, bei jedem Lauf neu gemessen. =====
      -- Sie stoppen nichts. Ob ein Schwellenwert daraus eine Pflichtregel macht, ist ein Fachentscheid.
      UNION ALL SELECT 'W01', 'WARNUNG', 'Eindeutigkeit', 'Kassenpositionen, die eine identische Vorgängerzeile haben (doppelt übertragen oder 2 gleiche Artikel?)', 'PR-02',
        (SELECT COUNTIF(is_identical_repeat) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)
      UNION ALL SELECT 'W02', 'WARNUNG', 'Wertebereich', 'Stornopositionen (menge = -1)', 'PR-03',
        (SELECT COUNTIF(is_cancellation) FROM `daeng-spengmik-y5go.kino_build.fact_sales`)
      UNION ALL SELECT 'W03', 'WARNUNG', 'Beziehungen', 'Kassenpositionen mit Artikel ohne Stammdaten (als __UNKNOWN__ geführt)', 'PR-04',
        (SELECT COUNTIF(product_key = '__UNKNOWN__') FROM `daeng-spengmik-y5go.kino_build.fact_sales`)
      UNION ALL SELECT 'W04', 'WARNUNG', 'Zeit', 'Spieltage mit Vorstellungen, aber ohne Kassendaten (Kassenausfall oder Exportlücke)', 'PR-05',
        (SELECT COUNT(DISTINCT s.date_key) FROM `daeng-spengmik-y5go.kino_build.fact_screening` s
         LEFT JOIN (SELECT DISTINCT date_key FROM `daeng-spengmik-y5go.kino_build.fact_sales`) f USING (date_key)
         WHERE f.date_key IS NULL)
      UNION ALL SELECT 'W05', 'WARNUNG', 'Wertebereich', 'Vorstellungen mit mehr Tickets als Plätzen', 'PR-07',
        (SELECT COUNTIF(is_over_capacity) FROM `daeng-spengmik-y5go.kino_build.fact_screening`)
      UNION ALL SELECT 'W06', 'WARNUNG', 'Vollständigkeit', 'Inventurzeilen ohne Zählung', 'PR-10',
        (SELECT COUNTIF(count_status = 'NOT_COUNTED') FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count`)
      UNION ALL SELECT 'W07', 'WARNUNG', 'Konsistenz', 'Zählungen, die vom verbuchten Bestand abweichen', 'PR-11',
        (SELECT COUNTIF(variance_units != 0) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count`)
      UNION ALL SELECT 'W08', 'WARNUNG', 'Vollständigkeit', 'Bestellungen ohne Lieferdatum oder Liefermenge', 'PR-14',
        (SELECT COUNTIF(delivery_status = 'INCOMPLETE_RECORD') FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery`)
      UNION ALL SELECT 'W09', 'WARNUNG', 'Wertebereich', 'Lieferungen am Bestelltag oder früher (vermutlich Erfassungsfehler)', 'PR-15',
        (SELECT COUNTIF(is_nonpositive_lead_time) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery`)
      UNION ALL SELECT 'W10', 'WARNUNG', 'Korrektheit', 'Teillieferungen (geliefert < bestellt)', 'PR-16',
        (SELECT COUNTIF(is_partial_delivery) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery`)
      UNION ALL SELECT 'W11', 'WARNUNG', 'Zeit', 'Buchbestand ohne Historie: nur ein Änderungszeitpunkt für alle Produkte', 'PR-13',
        (SELECT IF(COUNT(DISTINCT last_changed_at_local) <= 1, 1, 0) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot`)
    );

    SET v_failed_mandatory = (SELECT COUNTIF(NOT passed) FROM `daeng-spengmik-y5go.kino_ops.dq_results`
                              WHERE run_id = v_run_id AND severity = 'PFLICHT');
    SET v_warnings = (SELECT COUNTIF(NOT passed) FROM `daeng-spengmik-y5go.kino_ops.dq_results`
                      WHERE run_id = v_run_id AND severity = 'WARNUNG');

    -- ===== 3. Schranke und Veröffentlichen ================================================
    IF p_publish AND v_failed_mandatory = 0 THEN
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.dim_date` COPY `daeng-spengmik-y5go.kino_build.dim_date`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.dim_product` COPY `daeng-spengmik-y5go.kino_build.dim_product`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.dim_auditorium` COPY `daeng-spengmik-y5go.kino_build.dim_auditorium`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.dim_film` COPY `daeng-spengmik-y5go.kino_build.dim_film`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.dim_supplier` COPY `daeng-spengmik-y5go.kino_build.dim_supplier`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.fact_sales` COPY `daeng-spengmik-y5go.kino_build.fact_sales`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.fact_screening` COPY `daeng-spengmik-y5go.kino_build.fact_screening`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.fact_inventory_count` COPY `daeng-spengmik-y5go.kino_build.fact_inventory_count`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.fact_inventory_snapshot` COPY `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.fact_order_delivery` COPY `daeng-spengmik-y5go.kino_build.fact_order_delivery`;
      CREATE OR REPLACE TABLE `daeng-spengmik-y5go.kino_star.cube_sales_monthly` COPY `daeng-spengmik-y5go.kino_build.cube_sales_monthly`;
      SET v_published = TRUE;
    END IF;

    -- ===== 4. Laufprotokoll ===============================================================
    INSERT INTO `daeng-spengmik-y5go.kino_ops.pipeline_runs`
      (run_id, started_at, finished_at, triggered_by, publish_requested, test_fail, status, published,
       failed_mandatory, warnings, row_counts, message)
    VALUES (v_run_id, v_started, CURRENT_TIMESTAMP(), SESSION_USER(), p_publish, p_test_fail,
      IF(v_failed_mandatory = 0, 'SUCCEEDED', 'BLOCKED'), v_published, v_failed_mandatory, v_warnings, v_counts,
      CASE
        WHEN v_failed_mandatory > 0 THEN FORMAT('%d Pflichtprüfung(en) nicht bestanden, kino_star unverändert', v_failed_mandatory)
        WHEN v_published THEN 'Alle Pflichtprüfungen bestanden, kino_star ersetzt'
        ELSE 'Alle Pflichtprüfungen bestanden, nur gebaut (p_publish = FALSE)'
      END);

  EXCEPTION WHEN ERROR THEN
    -- Technischer Fehler (z. B. Rohdaten im falschen Format): protokollieren, dann scheitern.
    INSERT INTO `daeng-spengmik-y5go.kino_ops.pipeline_runs`
      (run_id, started_at, finished_at, triggered_by, publish_requested, test_fail, status, published,
       failed_mandatory, warnings, row_counts, message)
    VALUES (v_run_id, v_started, CURRENT_TIMESTAMP(), SESSION_USER(), p_publish, p_test_fail,
      'ERROR', FALSE, NULL, NULL, NULL, @@error.message);
    RAISE USING MESSAGE = CONCAT('Pipeline-Fehler, siehe kino_ops.pipeline_runs: ', @@error.message);
  END;

  -- Ein blockierter Lauf endet als Fehler, damit er nicht übersehen wird.
  IF v_failed_mandatory > 0 THEN
    RAISE USING MESSAGE = FORMAT('Pipeline blockiert: %d Pflichtprüfung(en) nicht bestanden. kino_star unverändert. Details: SELECT * FROM kino_ops.dq_results WHERE run_id = "%s"',
      v_failed_mandatory, v_run_id);
  END IF;

  SELECT v_run_id AS run_id, IF(v_failed_mandatory = 0, 'SUCCEEDED', 'BLOCKED') AS status,
    v_published AS published, v_failed_mandatory AS failed_mandatory, v_warnings AS warnings, v_counts AS row_counts;
END;
