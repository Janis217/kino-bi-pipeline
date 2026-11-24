# Entscheide aus der Umsetzung

Die Pipeline (Woche 11) hat Claude umgesetzt. Diese Liste nennt jede Stelle, an der dabei etwas entschieden werden musste, das kein Auftrag vorgab. Das Team prüft jeden Punkt im Review und übernimmt ihn, ändert ihn oder verwirft ihn. Übernommene Punkte kommen ins Projektjournal.

Review: 24.11.2026, Janis (Pull Request #1). E-01 bis E-06 übernommen; F-01 und F-02 bleiben offen.

Status: **vorgeschlagen** = von Claude, noch nicht vom Team geprüft · **übernommen** · **offen** = braucht einen Fachentscheid.

## Technische Entscheide

### E-01 · Transformation in BigQuery statt in `deploy.py` · übernommen
Das Sternschema wurde bisher lokal in Python gebaut und fertig hochgeladen. Der Weg von roh zu Stern war in der GCP nicht sichtbar. Neu baut SQL in BigQuery das Sternschema aus `kino_raw` (Views in `kino_stg`, Prozedur `kino_ops.run_pipeline`).
**Warum:** Transformation nachvollziehbar und wiederholbar (Folie 8, Woche 10). Abgleich mit dem alten Stand: 0 abweichende Zeilen in allen 11 Tabellen (`docs/nachweise.md`).

### E-02 · Zeilenschlüssel der Kasse neu gebildet · übernommen
Früher: Hash der Zeilennummer in der CSV-Datei. Die Zeilennummer ist in `kino_raw` nicht gespeichert und deshalb aus BigQuery nicht rekonstruierbar. Neu: Hash aus Beleg, Zeit, Artikel, Menge, Betrag und laufender Nummer unter identischen Zeilen. Die Spalte `source_row_number` entfällt, neu gibt es `occurrence_no`.
**Warum:** Der Schlüssel hängt nicht mehr an der Reihenfolge der Datei; dieselbe Lieferung ergibt immer dieselben Schlüssel (geprüft in Nachweis 2).
**Folge:** Wer `sales_line_key` oder `source_row_number` irgendwo verwendet hat, muss nachziehen. In den drei Views von `kino_star` wird keines davon verwendet.

### E-03 · Zeilenschlüssel der Bestellungen neu gebildet · übernommen
Früher: Hash der Dateizeile. Neu: Hash der `bestell_id`.
**Warum:** Die `bestell_id` ist in den Daten eindeutig (bei jedem Lauf geprüft, Regel Q03). Ein fachlicher Schlüssel ist stabiler als eine Zeilennummer.

### E-04 · Erst bauen, dann prüfen, dann veröffentlichen · übernommen
Jeder Lauf baut in `kino_build`. Nach `kino_star` kopiert wird nur, wenn alle Pflichtprüfungen bestehen. Ein blockierter Lauf endet als Fehler und steht im Laufprotokoll.
**Warum:** Schlechte Daten erreichen die Analysen nie (Qualitätsschranke wie im Data Engineering Tutorial, Lektion 2). Getestet mit einer absichtlich fehlschlagenden Regel (Nachweis 3).

### E-05 · Regeln statt fester Zahlen · übernommen
Die früheren Prüfungen hatten die Zeilenzahlen fest eingetragen (16'148, 69, …) und wären mit jeder neuen Lieferung gescheitert. Die neuen Regeln vergleichen roh mit Stern und prüfen Schlüssel und Beziehungen; sie gelten auch für neue Lieferungen.

### E-06 · Umwandlungsfehler werden gezählt, nicht verschluckt · übernommen
Jede Staging-View zählt Felder, die im Rohwert gefüllt sind, aber nicht umgewandelt werden konnten (`cast_errors`). Pflichtregel Q02 verlangt 0. Ganzzahlen wie `540.0` werden zu 540; `540.5` gilt als Fehler, statt stillschweigend gerundet zu werden.

## Fachliche Punkte

### F-01 · Identische Kassenzeilen · offen
509 Kassenpositionen haben eine vollständig identische Vorgängerzeile (PR-02). Sie bleiben im Stern und sind als `is_identical_repeat` markiert. Ob es Doppelübertragungen sind (dann weglassen) oder zwei gleiche Artikel auf einem Beleg (dann zählen), kann nur das Kassensystem bzw. die Kioskleitung klären.
**Wer entscheidet:** Domänenrolle.

### F-02 · Ab wann stoppt ein Befund den Lauf? · offen
Die 11 Warnungen (W01–W11) messen die Befunde aus dem Profiling bei jedem Lauf neu, stoppen aber nichts. Ob zum Beispiel «mehr als 5 Vorstellungen über Kapazität» oder «mehr als 1 Spieltag ohne Kassendaten» eine Lieferung unbrauchbar macht, ist ein Fachentscheid. Er würde aus einer Warnung eine Pflichtregel mit Schwellenwert machen.
**Wer entscheidet:** Domänenrolle, mit Analyse-Rolle.

### F-03 · Popcorn ausserhalb des Nachbestell-Modells · übernommen (Projektentscheid)
`in_replenishment_scope = FALSE` für die Gruppe Popcorn, wie im Projekt entschieden (lagerfähige Snacks).

### F-04 · Verkäufe sind nicht Nachfrage · bekannt
`fact_sales` enthält nur erfüllte Verkäufe. Ausverkauf und verlorene Verkäufe sind nicht sichtbar (PR-06, Folie 21 Woche 10). Die Pipeline ändert daran nichts; sie macht die Lücke in `v_replenishment_readiness` sichtbar.
