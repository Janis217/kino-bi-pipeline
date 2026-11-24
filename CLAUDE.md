# Arbeitsregeln für den Coding-Agenten

Projekt: Kino-BI-Pipeline, Team Data-Miners, BI HS 2026. Antworte auf Deutsch in Schweizer Rechtschreibung (ss statt ß).

## Arbeitsweise
- Plane, bevor du Dateien änderst, und warte auf das Go. (Das Team entscheidet, was sich ändert.)
- Ein Paket pro Pull Request: ein Zweck, unter etwa 200 geänderten Zeilen. (Kleine PRs bleiben prüfbar.)
- Nie direkt auf `main` committen; auf einem Branch arbeiten, pushen nur nach Go. (`main` enthält nur geprüfte Arbeit.)
- Ein Paket beginnt als Issue mit der Vorlage «Paket», das eine Person schreibt; der Pull Request schliesst dieses Issue.
- Jeder Entscheid, den das Issue offen lässt, kommt in `docs/entscheide.md` mit Status «vorgeschlagen». Wo das Team nichts entschieden hat: fragen oder als offen markieren, nicht selbst füllen.

## Daten und GCP
- Die Daten sind simuliert. Das steht in jedem Dokument, das Zahlen zeigt.
- Keine Daten ins Repo, nur Code und Dokumentation.
- `kino_raw` wird nie verändert. Typumwandlung nur in `kino_stg`.
- Neue Prüfregeln: ohne fest eingetragene Zeilenzahlen; Warnung oder Pflicht ist ein Fachentscheid des Teams.
- Nach jeder Änderung an `sql/`: in BigQuery ausführen, `sql/30_nachweise.sql` laufen lassen und das Ergebnis im Pull Request nennen.
- `kino_star` nur über `run_pipeline(TRUE, …)` verändern, nie direkt.
