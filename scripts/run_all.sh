#!/usr/bin/env bash
# Rebuilds the SeunBaba database from scratch and regenerates every text evidence
# file of Portfolios 1-4. Screenshots are produced afterwards by make_screenshots.sh.
# Prerequisites: PostgreSQL 16 on localhost:5432, MongoDB replica set rs0 on
# localhost:27017, Redis on localhost:6379, python3 with psycopg2-binary, pymongo, redis.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL="psql -h localhost -U postgres -d seunbaba"
MONGOSH="${MONGOSH:-mongosh}"

echo "== Portfolio 1: schema + seed"
cd "$ROOT/portfolio-1-database-design"
$PSQL -q -v ON_ERROR_STOP=1 -f sql/Odunlade_Oluwaseun_301931438_01_schema.sql 2>/dev/null
$PSQL -q -v ON_ERROR_STOP=1 -f sql/Odunlade_Oluwaseun_301931438_02_reference_data.sql
time $PSQL -q -v ON_ERROR_STOP=1 -f sql/Odunlade_Oluwaseun_301931438_03_seed_data.sql > /dev/null
$PSQL -e -f sql/Odunlade_Oluwaseun_301931438_04_constraint_tests.sql > evidence/Odunlade_Oluwaseun_301931438_04_constraint_tests_output.txt 2>&1 || true
$PSQL -c "\dt+ seunbaba.*" -c "\d seunbaba.customer_order" -c "\d seunbaba.inventory" > evidence/Odunlade_Oluwaseun_301931438_05_schema_overview.txt

echo "== Portfolio 2: benchmark before/after"
cd "$ROOT/portfolio-2-query-optimisation"
rm -rf evidence/before evidence/after
python3 Odunlade_Oluwaseun_301931438_run_benchmark.py before
$PSQL -e -f sql/Odunlade_Oluwaseun_301931438_02_indexes.sql > evidence/Odunlade_Oluwaseun_301931438_02_indexes_output.txt 2>&1
$PSQL -f sql/Odunlade_Oluwaseun_301931438_04_materialized_view.sql > evidence/Odunlade_Oluwaseun_301931438_04_materialized_view_output.txt 2>&1
python3 Odunlade_Oluwaseun_301931438_run_benchmark.py after
python3 Odunlade_Oluwaseun_301931438_run_benchmark.py report
python3 Odunlade_Oluwaseun_301931438_q4_regression_diagnosis.py > evidence/Odunlade_Oluwaseun_301931438_Q4_regression_diagnosis.txt

echo "== Portfolio 3: transactions"
cd "$ROOT/portfolio-3-transactions-concurrency"
$PSQL -q -v ON_ERROR_STOP=1 -f sql/01_checkout_functions.sql
$PSQL -q -f sql/00_demo_setup.sql > /dev/null
$PSQL -e -f sql/02_commit_rollback_demo.sql > evidence/02_commit_rollback_output.txt 2>&1 || true
python3 scripts/concurrency_demos.py > /dev/null

echo "== Portfolio 4: MongoDB + Redis"
cd "$ROOT/portfolio-4-nosql"
python3 mongodb/01_migrate_from_postgres.py | tee evidence/01_migration_output.txt
$MONGOSH --quiet "mongodb://localhost:27017/seunbaba?replicaSet=rs0" mongodb/02_queries.js > evidence/02_mongodb_queries_output.txt 2>&1
$MONGOSH --quiet "mongodb://localhost:27017/seunbaba?replicaSet=rs0" mongodb/03_transaction.js > evidence/03_mongodb_transaction_output.txt 2>&1
python3 redis/redis_demo.py > evidence/04_redis_output.txt
python3 crosscheck_sql_vs_mongo.py > evidence/05_sql_vs_mongodb_crosscheck.txt
echo "done"
