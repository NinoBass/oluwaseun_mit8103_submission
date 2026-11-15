#!/usr/bin/env bash
# Portfolio 5 - create a hot standby of the OjaHub primary using physical
# (WAL) streaming replication.
#   primary : localhost:5432  (wal_level=replica, max_wal_senders=10, wal_log_hints=on)
#   standby : localhost:5433  (read-only, hot_standby=on)
set -euo pipefail
PGBIN=/usr/lib/postgresql/16/bin
WORK=/var/lib/postgresql/work
STANDBY=$WORK/standby
PSQL="psql -h localhost -U postgres -X -q"

echo "== 1. replication slot on the primary (primary keeps WAL until the standby has it)"
$PSQL -p 5432 -c "SELECT pg_drop_replication_slot('standby1') FROM pg_replication_slots WHERE slot_name='standby1'" >/dev/null
$PSQL -p 5432 -c "SELECT slot_name, lsn FROM pg_create_physical_replication_slot('standby1')"

echo "== 2. base backup of the running primary (online, no downtime)"
rm -rf "$STANDBY"
time su postgres -c "$PGBIN/pg_basebackup -d 'host=localhost port=5432 user=postgres application_name=standby1' \
      -D $STANDBY -R -S standby1 -X stream -c fast"
# -R writes standby.signal + primary_conninfo, so the copy starts as a standby
echo "port = 5433" >> "$STANDBY/postgresql.conf"
cat "$STANDBY/postgresql.auto.conf"

echo "== 3. start the standby"
su postgres -c "$PGBIN/pg_ctl -D $STANDBY -l $WORK/standby.log start -w" | tail -1
sleep 2
$PSQL -p 5432 -c "SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication"
$PSQL -p 5433 -c "SELECT pg_is_in_recovery() AS is_standby"
