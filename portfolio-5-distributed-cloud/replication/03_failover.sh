#!/usr/bin/env bash
# Portfolio 5 - unplanned failover, rejoin with pg_rewind, planned switchover back.
# Requires wal_keep_size large enough that the crashed primary still has the WAL
# pg_rewind needs (first attempt without it failed - see README section 3).
#   1. primary (5432) "crashes" (immediate shutdown = power loss)
#   2. standby (5433) is promoted -> new primary; measure RTO, check RPO (lost orders)
#   3. old primary is rewound (pg_rewind) and rejoins as a standby of 5433
#   4. planned switchover returns the roles to the original layout
set -uo pipefail
PGBIN=${PGBIN:-$(pg_config --bindir 2>/dev/null || echo /usr/lib/postgresql/16/bin)}
W=${PG_WORK:-/var/lib/postgresql/work}
PSQL="psql -h localhost -U postgres -d seunbaba -X -At"
# millisecond clock via perl: works with both GNU and BSD/macOS userlands
ts() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%03d", strftime("%H:%M:%S", localtime $t), ($t-int $t)*1000'; }
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -c "$1"; else bash -c "$1"; fi; }   # su only when run as root (Linux service user)

echo "[$(ts)] == 0. before: roles and last committed order"
echo "  5432 in_recovery=$($PSQL -p 5432 -c 'select pg_is_in_recovery()')  timeline=$($PSQL -p 5432 -c "select ('x'||substr(pg_walfile_name(pg_current_wal_lsn()),1,8))::bit(32)::int")"
echo "  5433 in_recovery=$($PSQL -p 5433 -c 'select pg_is_in_recovery()')"
# a customer order committed just before the crash (synchronous_commit=on, async standby)
LAST=$($PSQL -p 5432 -c "SET search_path=seunbaba; SELECT place_order(50, '[{\"product_id\": 100, \"qty\": 1}]')" | tail -1)
echo "  order $LAST committed on primary at $(ts)"
sleep 0.5

echo "[$(ts)] == 1. CRASH: immediate shutdown of the primary"
as_pg "$PGBIN/pg_ctl -D $W/primary stop -m immediate" | tail -1
$PSQL -p 5432 -c "select 1" 2>&1 | head -1 | sed 's/^/  client sees: /'

echo "[$(ts)] == 2. FAILOVER: promote the standby"
T0=$(ms)
as_pg "$PGBIN/pg_ctl -D $W/standby promote -w" | tail -1
until $PSQL -p 5433 -c "SET search_path=seunbaba; INSERT INTO shipment_event (shipment_id,event_status,event_location,event_time) VALUES (1,'IN_TRANSIT','failover-probe',now())" >/dev/null 2>&1; do sleep 0.05; done
T1=$(ms)
echo "  first successful write on new primary after $((T1 - T0)) ms (RTO of the database step)"
echo "  5433 in_recovery=$($PSQL -p 5433 -c 'select pg_is_in_recovery()')  timeline=$($PSQL -p 5433 -c "select ('x'||substr(pg_walfile_name(pg_current_wal_lsn()),1,8))::bit(32)::int")"
echo "  order $LAST present on new primary? $($PSQL -p 5433 -c "select count(*)=1 from seunbaba.customer_order where order_id=$LAST")  (RPO check)"
echo "  orders on new primary: $($PSQL -p 5433 -c 'select count(*) from seunbaba.customer_order')"

echo "[$(ts)] == 3. REJOIN: rewind the old primary and attach it as a standby of 5433"
$PSQL -p 5433 -c "SELECT pg_create_physical_replication_slot('standby_old_primary')" >/dev/null
as_pg "$PGBIN/pg_rewind --target-pgdata=$W/primary --source-server='host=localhost port=5433 user=postgres dbname=postgres' --progress" 2>&1 | tail -3 | sed 's/^/  /' \
  || { echo "  pg_rewind FAILED - old primary must NOT be started (split-brain risk)"; exit 1; }
cat >> $W/primary/postgresql.auto.conf <<EOF
primary_conninfo = 'host=localhost port=5433 user=postgres application_name=old_primary'
primary_slot_name = 'standby_old_primary'
EOF
as_pg "touch $W/primary/standby.signal"
# pg_rewind copies the source's config, including its port setting: put 5432 back
echo "port = 5432" >> $W/primary/postgresql.conf
as_pg "$PGBIN/pg_ctl -D $W/primary -l $W/primary.log start -w" | tail -1
sleep 2
$PSQL -p 5433 -c "select application_name, state, sync_state from pg_stat_replication" | sed 's/^/  pg_stat_replication on 5433: /'

echo "[$(ts)] == 4. PLANNED SWITCHOVER back to the original layout (zero data loss)"
as_pg "$PGBIN/pg_ctl -D $W/standby stop -m fast" | tail -1           # clean shutdown ships all WAL
as_pg "$PGBIN/pg_ctl -D $W/primary promote -w" | tail -1
perl -ni -e 'print unless /^primary_(conninfo|slot_name)/' $W/primary/postgresql.auto.conf   # 5432 is primary again
as_pg "$PGBIN/pg_rewind --target-pgdata=$W/standby --source-server='host=localhost port=5432 user=postgres dbname=postgres'" 2>&1 | tail -1 | sed 's/^/  /' \
  || { echo "  pg_rewind FAILED"; exit 1; }
cat >> $W/standby/postgresql.auto.conf <<EOF
primary_conninfo = 'host=localhost port=5432 user=postgres application_name=standby1'
primary_slot_name = 'standby1'
EOF
echo "port = 5433" >> $W/standby/postgresql.conf
as_pg "touch $W/standby/standby.signal"
$PSQL -p 5432 -c "SELECT pg_create_physical_replication_slot('standby1')" >/dev/null 2>&1 || true
$PSQL -p 5432 -c "SELECT pg_drop_replication_slot('standby_old_primary')" >/dev/null 2>&1 || true
as_pg "$PGBIN/pg_ctl -D $W/standby -l $W/standby.log start -w" | tail -1
sleep 2
echo "  5432 in_recovery=$($PSQL -p 5432 -c 'select pg_is_in_recovery()')  timeline=$($PSQL -p 5432 -c "select ('x'||substr(pg_walfile_name(pg_current_wal_lsn()),1,8))::bit(32)::int")"
$PSQL -p 5432 -c "select application_name, state, sync_state from pg_stat_replication" | sed 's/^/  pg_stat_replication on 5432: /'
echo "  failover probe row survived both role changes: $($PSQL -p 5432 -c "select count(*) from seunbaba.shipment_event where event_location='failover-probe'")"
$PSQL -p 5432 -c "DELETE FROM seunbaba.shipment_event WHERE event_location='failover-probe'" >/dev/null
echo "[$(ts)] done"
