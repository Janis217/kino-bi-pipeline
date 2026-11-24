# Nachweise

Ausgeführt am 24.11.2026 in `daeng-spengmik-y5go` mit `sql/30_nachweise.sql`. Wiederholbar; ändert nichts an `kino_star`.

## Erwartung, vor dem Lauf festgehalten

1. Der SQL-Bau ergibt dieselben Zeilen wie das bisherige, von `deploy.py` hochgeladene `kino_star`, ausser den bewusst neu gebildeten Zeilenschlüsseln (E-02, E-03).
2. Ein zweiter Lauf auf denselben Rohdaten ergibt dieselben Tabellen, Schlüssel eingeschlossen.
3. Wird Veröffentlichen verlangt und scheitert eine Pflichtregel, bleibt `kino_star` unverändert und der Lauf steht als BLOCKED im Protokoll.

## Ergebnis

### 1 · Neu = alt: bestanden
| Tabelle | Zeilen | abweichende Zeilen | verglichen |
|---|---:|---:|---|
| dim_date | 69 | 0 | alle Spalten |
| dim_product | 9 | 0 | alle Spalten |
| dim_auditorium | 9 | 0 | alle Spalten |
| dim_film | 7 | 0 | alle Spalten |
| dim_supplier | 2 | 0 | alle Spalten |
| fact_sales | 16'148 | 0 | alle ausser Zeilenschlüssel |
| fact_screening | 1'440 | 0 | alle Spalten |
| fact_inventory_count | 56 | 0 | alle Spalten |
| fact_inventory_snapshot | 8 | 0 | alle Spalten |
| fact_order_delivery | 112 | 0 | alle ausser Zeilenschlüssel |
| cube_sales_monthly | 100 | 0 | alle ausser Bauzeitpunkt |

### 2 · Wiederholbarkeit: bestanden
SHA-256 über alle Zeilen von 8 Tabellen vor und nach einem zweiten Lauf: alle 8 identisch.

### 3 · Schranke: bestanden
Lauf mit `run_pipeline(TRUE, TRUE)`: Status BLOCKED, gescheitert nur `Q99-test`, 0 geänderte Tabellen in `kino_star`. Meldung: «Pipeline blockiert: 1 Pflichtprüfung(en) nicht bestanden. kino_star unverändert.»

## Prüfregeln im normalen Lauf

35 Pflichtregeln, alle bestanden. 11 Warnungen, die die Befunde aus dem Profiling-Bericht (Woche 8) neu messen. Sie treffen dieselben Werte:

| Regel | Befund | gemessen | Profiling Woche 8 |
|---|---|---:|---|
| W01 | identische Kassenzeilen | 509 | PR-02: 509 |
| W02 | Stornos | 25 | PR-03: 25 |
| W03 | Artikel ohne Stammdaten | 12 | PR-04: 12 (P99) |
| W04 | Spieltage ohne Kassendaten | 1 | PR-05: 1 (29.09.) |
| W05 | Vorstellungen über Kapazität | 4 | PR-07: 4 |
| W06 | Inventur ohne Zählung | 4 | PR-10: 7 % von 56 |
| W07 | Zählung ≠ verbucht | 39 von 52 | PR-11: 75 % |
| W08 | Bestellung ohne Lieferdatum oder -menge | 17 | PR-14: 16 ohne Lieferdatum (+1 ohne Menge) |
| W09 | Lieferzeit ≤ 0 Tage | 1 | PR-15: 1 |
| W10 | Teillieferungen | 12 | PR-16: 12 |
| W11 | Bestand ohne Historie | ja | PR-13 |
