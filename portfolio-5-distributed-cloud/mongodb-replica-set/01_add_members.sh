#!/usr/bin/env bash
# Portfolio 5 - grow the single-node MongoDB replica set rs0 (used in Portfolio 4)
# to three members. New members perform an automatic initial sync.
set -euo pipefail
M=${MONGO_BIN:-$(dirname "$(command -v mongod)")}
SH=${MONGOSH:-mongosh}
MW=${MONGO_WORK:-/var/lib/mongo-work}
ML=${MONGO_LOGDIR:-/var/log/mongo-work}
for port in 27018 27019; do
  if pgrep -f "port $port" >/dev/null; then echo "mongod $port already running"; continue; fi
  mkdir -p "$MW/rs0-$port" "$ML"
  # started in the background with nohup instead of --fork (--fork is not supported on macOS)
  nohup "$M/mongod" --replSet rs0 --port $port --bind_ip localhost --dbpath "$MW/rs0-$port" \
            --logpath "$ML/rs0-$port.log" --wiredTigerCacheSizeGB 0.5 >/dev/null 2>&1 &
  until $SH --quiet --port $port --eval 'db.adminCommand({ping: 1})' >/dev/null 2>&1; do sleep 0.5; done
  echo "mongod $port started"
done
$SH --quiet --port 27017 --eval '
  const have = rs.conf().members.map(m => m.host);
  for (const h of ["localhost:27018", "localhost:27019"]) if (!have.includes(h)) rs.add({host: h, priority: 1});
  let t0 = Date.now();
  while (rs.status().members.some(m => m.stateStr !== "PRIMARY" && m.stateStr !== "SECONDARY")) sleep(500);
  print(`initial sync of 2 new members finished in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  rs.status().members.forEach(m => print(`${m.name}  ${m.stateStr.padEnd(9)}  health=${m.health}  lastApplied=${m.optimeDate.toISOString()}`));
  const sec = new Mongo("mongodb://localhost:27019/?directConnection=true&readPreference=secondary");
  const sdb = sec.getDB("seunbaba");
  print(`read directly from SECONDARY localhost:27019 -> orders=${sdb.orders.countDocuments({})}, products=${sdb.products.countDocuments({})}`);
  print(`same counts on PRIMARY                     -> orders=${db.getSiblingDB("seunbaba").orders.countDocuments({})}, products=${db.getSiblingDB("seunbaba").products.countDocuments({})}`);'
