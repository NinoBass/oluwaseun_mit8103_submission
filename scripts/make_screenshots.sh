#!/usr/bin/env bash
# Regenerates every PNG screenshot from the text evidence produced by run_all.sh
# (and, for Portfolio 5, by its own scripts). Needs node + playwright, and
# MERMAID_JS=/path/to/node_modules/mermaid/dist/mermaid.min.js for the ERD.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="node $ROOT/scripts/render_evidence.js"
TMP="$(mktemp -d)"
cd "$ROOT"
# versions shown in the window titles are read from the running servers, not hard-coded
PGV="PostgreSQL $(psql -h localhost -U postgres -d postgres -XAtc 'SHOW server_version' | cut -d' ' -f1)"
MGV="MongoDB $(mongosh --quiet --port 27017 --eval 'db.version()')"
RDV="Redis $(redis-cli INFO server | sed -n 's/^redis_version:\(.*\)\r$/\1/p')"

# ---- Portfolio 1
if [ -n "${MERMAID_JS:-}" ]; then
  $R mermaid portfolio-1-database-design/diagrams/Odunlade_Oluwaseun_301931438_seunbaba_erd.mmd portfolio-1-database-design/diagrams/Odunlade_Oluwaseun_301931438_seunbaba_erd.png
  $R mermaid portfolio-5-distributed-cloud/cloud/architecture.mmd portfolio-5-distributed-cloud/cloud/architecture.png
fi
E=portfolio-1-database-design/evidence
grep -E "^====|ERROR|order_id \||-----\+-|^ +1 \|" $E/Odunlade_Oluwaseun_301931438_04_constraint_tests_output.txt | sed '1,2d; s/^psql:sql\/Odunlade_Oluwaseun_301931438_04_constraint_tests.sql:[0-9]*: //' > $TMP/p1.txt
$R term $TMP/p1.txt $E/Odunlade_Oluwaseun_301931438_04_constraint_tests.png "psql seunbaba -f Odunlade_Oluwaseun_301931438_04_constraint_tests.sql ($PGV)"

# ---- Portfolio 2
E=portfolio-2-query-optimisation/evidence
{ echo "### BEFORE (no FK indexes) ###"; sed -n '/^$/,$p' $E/before/Odunlade_Oluwaseun_301931438_Q2_plan.txt | sed '/^$/d' | cut -c1-165
  echo; echo "### AFTER (ix_shipment_order + ix_shipment_event_ship) ###"; sed -n '/^$/,$p' $E/after/Odunlade_Oluwaseun_301931438_Q2_plan.txt | sed '/^$/d' | cut -c1-165; } > $TMP/q2.txt
$R term $TMP/q2.txt $E/Odunlade_Oluwaseun_301931438_Q2_plan_before_after.png "EXPLAIN (ANALYZE, BUFFERS) - Q2 order tracking"
cut -c1-190 $E/Odunlade_Oluwaseun_301931438_Q4_regression_diagnosis.txt > $TMP/q4.txt
$R term $TMP/q4.txt $E/Odunlade_Oluwaseun_301931438_Q4_regression_diagnosis.png "python3 Odunlade_Oluwaseun_301931438_q4_regression_diagnosis.py"
python3 - "$E" > $TMP/bench.txt <<'EOF'
import json, sys
e = sys.argv[1]
b = json.load(open(f"{e}/Odunlade_Oluwaseun_301931438_timings_before.json")); a = json.load(open(f"{e}/Odunlade_Oluwaseun_301931438_timings_after.json"))
print(f"{'Query':28}{'Before ms':>12}{'After ms':>12}{'Speed-up':>10}{'Buffers before':>16}{'Buffers after':>15}")
print("-" * 93)
rows = [(q + ' + indexes', b[q], a[q]) for q in b]
for q in ['Q4', 'Q7']:
    rows.insert([r[0] for r in rows].index(q + ' + indexes') + 1, (f"{q} -> {q}b rewrite", b[q], a[q + 'b']))
for n, x, y in rows:
    print(f"{n:28}{x['median_exec_ms']:12.2f}{y['median_exec_ms']:12.2f}{x['median_exec_ms'] / y['median_exec_ms']:9.1f}x"
          f"{x['shared_hit_blocks'] + x['shared_read_blocks']:16,}{y['shared_hit_blocks'] + y['shared_read_blocks']:15,}")
EOF
$R term $TMP/bench.txt $E/Odunlade_Oluwaseun_301931438_benchmark_summary.png "python3 Odunlade_Oluwaseun_301931438_run_benchmark.py report  (median of 7 runs)"

# ---- Portfolio 3
E=portfolio-3-transactions-concurrency/evidence
grep -E "^(##########|psql:|ERROR| SBB|ROLLBACK$|COMMIT$| PAID|      sku| order_id| orders_| +[0-9]{6} \|| +[0-9]+$| FLASH3| coupon_code)" \
  $E/02_commit_rollback_output.txt | sed 's/^psql:sql\/02_commit_rollback_demo.sql:[0-9]*: //' > $TMP/p3.txt
$R term $TMP/p3.txt $E/02_commit_rollback.png "psql -f 02_commit_rollback_demo.sql (condensed)"
for f in D1_lost_update D2_non_repeatable_read D3_write_skew D4_deadlock D5_flash_sale_stress; do
  cut -c1-175 $E/$f.txt > $TMP/$f.txt
  $R term $TMP/$f.txt $E/$f.png "python3 concurrency_demos.py ${f%%_*}  ($PGV, separate connections)"
done

# ---- Portfolio 4
E=portfolio-4-nosql/evidence
cat $E/01_migration_output.txt > $TMP/m0.txt
$R term $TMP/m0.txt $E/01_migration.png "python3 01_migrate_from_postgres.py"
grep -E "########|plan=|matching|REJECTED|orders=|#[1-3] |name: '|score|forced|with index" $E/02_mongodb_queries_output.txt | cut -c1-170 > $TMP/m1.txt
$R term $TMP/m1.txt $E/02_mongodb_queries.png "mongosh seunbaba 02_queries.js ($MGV, replica set rs0) - condensed"
$R term $E/03_mongodb_transaction_output.txt $E/03_mongodb_transaction.png "mongosh seunbaba 03_transaction.js"
cut -c1-180 $E/04_redis_output.txt > $TMP/r.txt
$R term $TMP/r.txt $E/04_redis.png "python3 redis_demo.py ($RDV)"
$R term $E/05_sql_vs_mongodb_crosscheck.txt $E/05_crosscheck.png "python3 crosscheck_sql_vs_mongo.py"

# ---- Portfolio 5 (only if its evidence exists)
E=portfolio-5-distributed-cloud/evidence
for f in $E/*.txt; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .txt)
  if [ "$b" = "S_sharding_demo" ]; then        # condense: headers, plan shape, remote SQL, results
    grep -E "^====|Foreign Scan|Remote SQL|Aggregate|Append|shard[12]|^ +[A-Z][a-z]+ [A-Z][a-z]+ +\||^ +[0-9]+ +\| +[0-9]+ +\||side \||left_after|^ +0$" "$f" \
      | sed -E 's/^ {10,}/      /' | cut -c1-175 > $TMP/$b.txt
  else
    cut -c1-175 "$f" > $TMP/$b.txt
  fi
  $R term $TMP/$b.txt $E/$b.png "$b"
done
rm -rf "$TMP"
echo "screenshots regenerated"
