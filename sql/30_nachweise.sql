-- Kino BI · Woche 11 · 30_nachweise: die drei Nachweise, jederzeit wiederholbar. Ändern nichts an kino_star.
-- Ergebnis am 24.11.2026: (1) 0 abweichende Zeilen in allen 11 Tabellen, (2) alle Fingerabdrücke
-- identisch, (3) Lauf BLOCKED, 0 geänderte Tabellen in kino_star, gescheitert nur Q99-test.

SET @@location = 'europe-west6';

-- ===== Nachweis 1: SQL-Bau = bisheriges, von deploy.py hochgeladenes kino_star ==============
-- Vor der ersten Veröffentlichung ausführen (danach vergleicht er kino_build mit sich selbst).
-- Multimengen-Vergleich: jede Zeile als JSON, in beide Richtungen gezählt.
-- Nicht verglichen: die Zeilenschlüssel von fact_sales und fact_order_delivery (bewusst neu
-- gebildet, siehe README) und der Bauzeitpunkt des Würfels.
CREATE TEMP FUNCTION diff(a ARRAY<STRING>, b ARRAY<STRING>) AS ((
  SELECT COUNT(*) FROM (
    SELECT j, SUM(s) c FROM (SELECT j, 1 s FROM UNNEST(a) j UNION ALL SELECT j, -1 FROM UNNEST(b) j)
    GROUP BY j HAVING c != 0)));
SELECT 'dim_date' t, diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.dim_date` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.dim_date` x)) abweichende_zeilen
UNION ALL SELECT 'dim_product', diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.dim_product` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.dim_product` x))
UNION ALL SELECT 'dim_auditorium', diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.dim_auditorium` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.dim_auditorium` x))
UNION ALL SELECT 'dim_film', diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.dim_film` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.dim_film` x))
UNION ALL SELECT 'dim_supplier', diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.dim_supplier` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.dim_supplier` x))
UNION ALL SELECT 'fact_sales', diff(ARRAY(SELECT TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (sales_line_key, source_row_number))) FROM `daeng-spengmik-y5go.kino_star.fact_sales` x), ARRAY(SELECT TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (sales_line_key, occurrence_no))) FROM `daeng-spengmik-y5go.kino_build.fact_sales` x))
UNION ALL SELECT 'fact_screening', diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.fact_screening` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.fact_screening` x))
UNION ALL SELECT 'fact_inventory_count', diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.fact_inventory_count` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_count` x))
UNION ALL SELECT 'fact_inventory_snapshot', diff(ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_star.fact_inventory_snapshot` x), ARRAY(SELECT TO_JSON_STRING(x) FROM `daeng-spengmik-y5go.kino_build.fact_inventory_snapshot` x))
UNION ALL SELECT 'fact_order_delivery', diff(ARRAY(SELECT TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (order_line_key))) FROM `daeng-spengmik-y5go.kino_star.fact_order_delivery` x), ARRAY(SELECT TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (order_line_key))) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery` x))
UNION ALL SELECT 'cube_sales_monthly', diff(ARRAY(SELECT TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (built_at))) FROM `daeng-spengmik-y5go.kino_star.cube_sales_monthly` x), ARRAY(SELECT TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (built_at))) FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly` x));

-- ===== Nachweis 2: Wiederholbarkeit =========================================================
-- Fingerabdruck (SHA-256 über alle Zeilen, sortiert) vor und nach einem zweiten Lauf.
CREATE TEMP TABLE before AS
SELECT 'fact_sales' t, TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING(x), '\n' ORDER BY TO_JSON_STRING(x)))) fp FROM `daeng-spengmik-y5go.kino_build.fact_sales` x
UNION ALL SELECT 'fact_screening', TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING(x), '\n' ORDER BY TO_JSON_STRING(x)))) FROM `daeng-spengmik-y5go.kino_build.fact_screening` x
UNION ALL SELECT 'fact_order_delivery', TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING(x), '\n' ORDER BY TO_JSON_STRING(x)))) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery` x
UNION ALL SELECT 'cube_sales_monthly', TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (built_at))), '\n' ORDER BY TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (built_at)))))) FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly` x;
CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(FALSE, FALSE);
CREATE TEMP TABLE after AS
SELECT 'fact_sales' t, TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING(x), '\n' ORDER BY TO_JSON_STRING(x)))) fp FROM `daeng-spengmik-y5go.kino_build.fact_sales` x
UNION ALL SELECT 'fact_screening', TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING(x), '\n' ORDER BY TO_JSON_STRING(x)))) FROM `daeng-spengmik-y5go.kino_build.fact_screening` x
UNION ALL SELECT 'fact_order_delivery', TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING(x), '\n' ORDER BY TO_JSON_STRING(x)))) FROM `daeng-spengmik-y5go.kino_build.fact_order_delivery` x
UNION ALL SELECT 'cube_sales_monthly', TO_HEX(SHA256(STRING_AGG(TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (built_at))), '\n' ORDER BY TO_JSON_STRING((SELECT AS STRUCT x.* EXCEPT (built_at)))))) FROM `daeng-spengmik-y5go.kino_build.cube_sales_monthly` x;
SELECT t, b.fp = a.fp AS identisch FROM before b JOIN after a USING (t);

-- ===== Nachweis 3: die Schranke hält =========================================================
-- Veröffentlichen verlangt, aber Testregel Q99 scheitert. Erwartet: Lauf BLOCKED, kino_star unverändert.
CREATE TEMP TABLE star_before AS
SELECT table_id, last_modified_time FROM `daeng-spengmik-y5go.kino_star.__TABLES__`;
BEGIN
  CALL `daeng-spengmik-y5go.kino_ops.run_pipeline`(TRUE, TRUE);
EXCEPTION WHEN ERROR THEN
  CREATE TEMP TABLE gate_error AS SELECT @@error.message AS message;
END;
SELECT
  (SELECT message FROM gate_error) AS fehlermeldung_der_pipeline,
  (SELECT COUNT(*) FROM star_before b JOIN `daeng-spengmik-y5go.kino_star.__TABLES__` a USING (table_id)
    WHERE a.last_modified_time != b.last_modified_time) AS geaenderte_tabellen_in_kino_star;

-- ===== Für den Alltag ======================================================================
-- Letzte Läufe:      SELECT * FROM `daeng-spengmik-y5go.kino_ops.pipeline_runs` ORDER BY started_at DESC;
-- Letzte Prüfungen:  SELECT rule_id, severity, observed, passed, description, profiling_ref
--                    FROM `daeng-spengmik-y5go.kino_ops.dq_results`
--                    WHERE run_id = (SELECT run_id FROM `daeng-spengmik-y5go.kino_ops.pipeline_runs` ORDER BY started_at DESC LIMIT 1)
--                    ORDER BY severity, rule_id;
