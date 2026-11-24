# Kino-BI-Pipeline

Team Data-Miners (Team 2), Modul Business Intelligence HS 2026, ZHAW.
Fall: Kino mit mehreren Sälen, Entscheidung «Snack-Nachbestellung vor Spitzentagen» (DC-01).

> **Die Daten sind simuliert** (Datenbasis Woche 8, 07.09.–01.11.2026), keine echten Kino-Daten.
> Sie liegen nur in BigQuery, nicht in diesem Repo.

## Wo was liegt

| Ort | Inhalt |
|---|---|
| **Dieses Repo** | Code (SQL), Entscheide, Nachweise, Arbeitspakete als Issues, Änderungen als Pull Requests |
| **Google Cloud** (`daeng-spengmik-y5go`, `europe-west6`) | Daten und Ausführung: BigQuery-Datasets, Prozedur, Prüfergebnisse |

Code aus dem Repo kommt nicht automatisch in die GCP: Nach einem Merge wird das geänderte SQL in BigQuery ausgeführt (heute von Hand bzw. über den BigQuery-Connector).

## Was läuft

Ein Aufruf baut Sternschema und OLAP-Würfel aus den Rohdaten neu, prüft sie und veröffentlicht sie nur, wenn alle Pflichtprüfungen bestehen:

```sql
CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(TRUE, FALSE);   -- bauen, prüfen, veröffentlichen
CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(FALSE, FALSE);  -- nur bauen und prüfen
CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(TRUE, TRUE);    -- Test: die Schranke muss blockieren
```

```
kino_raw    8 Tabellen, Text, so wie geliefert            Ingestion (Woche 8)
  ↓
kino_stg    8 Views: Datentypen, Flags, Umwandlungsfehler  Transformation
  ↓
kino_build  5 Dimensionen, 5 Fakten, Würfel                Transformation, bei jedem Lauf ersetzt
  ↓
Prüfungen   35 Pflicht + 11 Warnungen → kino_ops.dq_results  automatisierte Prüfungen
  ↓ Schranke: nur bei 0 gescheiterten Pflichtprüfungen
kino_star   Sternschema + Würfel, das die Analysen nutzen   Serving
            + Eintrag in kino_ops.pipeline_runs              Laufprotokoll
```

## Ordner

| Pfad | Inhalt |
|---|---|
| `sql/00_setup.sql` | Datasets `kino_stg`, `kino_build`, `kino_ops`; Tabellen für Laufprotokoll und Prüfergebnisse |
| `sql/10_staging.sql` | Funktion `to_int` und 8 Staging-Views |
| `sql/20_run_pipeline.sql` | Prozedur `kino_ops.run_pipeline`: bauen, prüfen, Schranke, Protokoll |
| `sql/30_nachweise.sql` | Abgleich mit dem alten Stand, zweiter Lauf, Test der Schranke |
| `docs/entscheide.md` | Entscheide aus der Umsetzung, offene Fachfragen |
| `docs/nachweise.md` | Ergebnisse der Nachweise mit Datum |
| `.github/ISSUE_TEMPLATE/paket.yml` | Vorlage für ein Arbeitspaket (5 Felder) |
| `CLAUDE.md` | Arbeitsregeln für den Coding-Agenten |

Neu aufsetzen: `00` → `10` → `20` in BigQuery ausführen, dann `CALL`. Alle Anweisungen sind wiederholbar (`IF NOT EXISTS`, `OR REPLACE`).

## Arbeitsweise

Nach dem Tutorial «ds-projekt-2026» (V. Pechtor): Ein Arbeitspaket beginnt als Issue mit der Vorlage **Paket**, das eine Person schreibt, bevor gearbeitet wird. Jede Änderung kommt über einen Branch und einen Pull Request nach `main`. Im Review wird geprüft, ob die Änderung das Issue erfüllt und welche Entscheide der Agent selbst getroffen hat (`docs/entscheide.md`).

## Nicht dabei

Ablage der Originaldateien in Cloud Storage, Zeitplan und Alarm per E-Mail (Data Engineering Tutorial, Lektion 1–2). Die Pipeline startet von Hand mit `CALL`.
