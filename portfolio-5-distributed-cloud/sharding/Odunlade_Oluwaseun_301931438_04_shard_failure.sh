#!/usr/bin/env bash
# Portfolio 5 - what happens to SeunBaba when one shard server goes down?
PSQL="psql -h localhost -U postgres -d seunbaba -X -q"
PGBIN=${PGBIN:-$(pg_config --bindir 2>/dev/null || echo /usr/lib/postgresql/16/bin)}
W=${PG_WORK:-$W}
as_pg() { if [ "$(id -u)" = 0 ]; then as_pg "$1"; else bash -c "$1"; fi; }   # su only when run as root (Linux service user)
echo "### stopping shard2 (port 5435) ###"
as_pg "$PGBIN/pg_ctl -D $W/shard_5435 stop -m fast" | tail -1
echo
echo "### customer 50 lives on shard1 -> still served ###"
$PSQL -c "SELECT customer_id, count(*) AS orders, tableoid::regclass AS served_by FROM dist.customer_order WHERE customer_id = 50 GROUP BY 1, 3" 2>&1
echo "### customer 1207 lives on shard2 -> unavailable ###"
$PSQL -c "SELECT customer_id, count(*) AS orders FROM dist.customer_order WHERE customer_id = 1207 GROUP BY 1" 2>&1 | head -3
echo "### company-wide report needs every shard -> fails ###"
$PSQL -c "SELECT count(*) FROM dist.customer_order" 2>&1 | head -3
echo
echo "### restarting shard2 ###"
as_pg "$PGBIN/pg_ctl -D $W/shard_5435 -l $W/shard_5435.log start -w" | tail -1
$PSQL -c "SELECT count(*) AS orders_all_shards FROM dist.customer_order" 2>&1
echo "Conclusion: sharding isolates failures (only ~50% of customers affected) but does not by itself"
echo "provide availability - each shard needs its own replica (next section: streaming replication)."
