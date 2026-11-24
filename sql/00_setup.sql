-- Kino BI, Team Data-Miners · Woche 11 · Data Engineering in BigQuery
-- 00_setup: Datasets und Betriebstabellen. Läuft einmal; jede Anweisung ist wiederholbar.
-- Daten sind simuliert (Woche 8), nicht echt.

-- Alle Datasets liegen in Zürich; ohne diese Zeile führt BigQuery das Skript in US aus.
SET @@location = 'europe-west6';

-- kino_stg: Rohdaten typisiert und mit Prüf-Flags. Nur Views, also immer aktuell zu kino_raw.
CREATE SCHEMA IF NOT EXISTS `daeng-spengmik-y5go.kino_stg`
OPTIONS (location = 'europe-west6',
  description = 'Staging: kino_raw typisiert, mit Prüf-Flags. Nur Views. Simulierte Daten.');

-- kino_build: hier baut jeder Lauf das Sternschema neu. Erst wenn alle Pflichtprüfungen
-- bestehen, wird es nach kino_star kopiert. So erreicht ein fehlerhafter Lauf kino_star nie.
CREATE SCHEMA IF NOT EXISTS `daeng-spengmik-y5go.kino_build`
OPTIONS (location = 'europe-west6',
  description = 'Bauplatz der Pipeline. Wird bei jedem Lauf ersetzt. Nicht direkt nutzen, nur kino_star.');

-- kino_ops: Prozedur, Laufprotokoll, Prüfergebnisse.
CREATE SCHEMA IF NOT EXISTS `daeng-spengmik-y5go.kino_ops`
OPTIONS (location = 'europe-west6',
  description = 'Betrieb der Pipeline: Prozedur run_pipeline, Laufprotokoll, Prüfergebnisse.');

-- Ein Eintrag pro Lauf. Wer, wann, mit welchem Ergebnis, und ob kino_star ersetzt wurde.
CREATE TABLE IF NOT EXISTS `daeng-spengmik-y5go.kino_ops.pipeline_runs` (
  run_id STRING NOT NULL,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  triggered_by STRING,
  publish_requested BOOL,
  test_fail BOOL,
  status STRING,              -- SUCCEEDED, BLOCKED (Pflichtprüfung nicht bestanden)
  published BOOL,             -- wurde kino_star in diesem Lauf ersetzt?
  failed_mandatory INT64,
  warnings INT64,
  row_counts JSON,            -- Zeilen pro gebauter Tabelle
  message STRING
)
OPTIONS (description = 'Laufprotokoll: ein Eintrag pro Aufruf von kino_ops.run_pipeline.');

-- Ein Eintrag pro Lauf und Regel. Massgebend ist passed.
CREATE TABLE IF NOT EXISTS `daeng-spengmik-y5go.kino_ops.dq_results` (
  run_id STRING NOT NULL,
  checked_at TIMESTAMP,
  rule_id STRING,
  severity STRING,            -- PFLICHT stoppt die Veröffentlichung, WARNUNG nur melden
  area STRING,                -- Eindeutigkeit, Beziehungen, Abgleich, Vollständigkeit, Wertebereich, ...
  description STRING,
  profiling_ref STRING,       -- Befund aus dem Profiling-Bericht Woche 8 (PR-xx), falls vorhanden
  observed INT64,             -- gemessene Anzahl Verstösse bzw. Fälle
  expected STRING,
  passed BOOL
)
OPTIONS (description = 'Prüfergebnisse: ein Eintrag pro Lauf und Regel. PFLICHT nicht bestanden = Lauf blockiert.');
