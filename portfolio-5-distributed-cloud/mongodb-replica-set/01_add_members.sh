#!/usr/bin/env bash
# Portfolio 5 - grow the single-node MongoDB replica set rs0 (used in Portfolio 4)
# to three members. New members perform an automatic initial sync.
set -euo pipefail
M=${MONGO_BIN:-/opt/mongo/mongodb-linux-x86_64-ubuntu2404-8.0.4/bin}
SH=${MONGOSH:-/opt/mongo/mongosh-2.3.8-linux-x64/bin/mongosh}
for port in 27018 27019; do
  if pgrep -f "port $port" >/dev/null; then echo "mongod $port already running"; continue; fi
  mkdir -p /var/lib/mongo-work/rs0-$port
  $M/mongod --replSet rs0 --port $port --bind_ip localhost --dbpath /var/lib/mongo-work/rs0-$port \
            --logpath /var/log/mongo-work/rs0-$port.log --fork --wiredTigerCacheSizeGB 0.5 | tail -1
done
$SH --quiet --port 27017 --eval '
  const have = rs.conf().members.map(m => m.host);
  for (const h of ["localhost:27018", "localhost:27019"]) if (!have.includes(h)) rs.add({host: h, priority: 1});
  let t0 = Date.now();
  while (rs.status().members.some(m => m.stateStr !== "PRIMARY" && m.stateStr !== "SECONDARY")) sleep(500);
  print(`initial sync of 2 new members finished in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  rs.status().members.forEach(m => print(`${m.name}  ${m.stateStr.padEnd(9)}  health=${m.health}  lastApplied=${m.optimeDate.toISOString()}`));
  const sec = new Mongo("mongodb://localhost:27019/?directConnection=true&readPreference=secondary");
  const sdb = sec.getDB("ojahub");
  print(`read directly from SECONDARY localhost:27019 -> orders=${sdb.orders.countDocuments({})}, products=${sdb.products.countDocuments({})}`);
  print(`same counts on PRIMARY                     -> orders=${db.getSiblingDB("ojahub").orders.countDocuments({})}, products=${db.getSiblingDB("ojahub").products.countDocuments({})}`);'
