#!/usr/bin/env python3
"""
Portfolio 5 - MongoDB replica set behaviour under failure (3 members, rs0).

  E1  write with w:"majority" and read it from a secondary
  E2  kill -9 the PRIMARY: measure time until a new primary is elected and the
      application's next write succeeds (driver retries automatically)
  E3  restart the crashed node: it rejoins as SECONDARY and catches up
  E4  lose the MAJORITY (2 of 3 down): no primary can exist -> writes refused,
      reads with readPreference=secondaryPreferred still served (CP behaviour)
"""
import os, signal, subprocess, time
from datetime import datetime, timezone
from pymongo import MongoClient, ReadPreference, WriteConcern
from pymongo.errors import PyMongoError

MONGOD = os.environ.get("MONGO_BIN", "/opt/mongo/mongodb-linux-x86_64-ubuntu2404-8.0.4/bin") + "/mongod"
URI = "mongodb://localhost:27017,localhost:27018,localhost:27019/?replicaSet=rs0&retryWrites=true"
T0 = time.perf_counter()


def log(msg):
    print(f"{time.perf_counter() - T0:7.3f}s  {msg}")


def direct(port):
    return MongoClient(f"mongodb://localhost:{port}/?directConnection=true", serverSelectionTimeoutMS=1500)


def topology():
    out = []
    for port in (27017, 27018, 27019):
        try:
            h = direct(port).admin.command("hello")
            out.append(f"{port}:{'PRIMARY' if h.get('isWritablePrimary') else ('SECONDARY' if h.get('secondary') else 'OTHER')}")
        except PyMongoError:
            out.append(f"{port}:DOWN")
    return "  ".join(out)


def kill(port):
    pid = direct(port).admin.command("serverStatus")["pid"]
    os.kill(int(pid), signal.SIGKILL)
    return pid


def start(port):
    dbpath = "/var/lib/mongo-work/rs0-1" if port == 27017 else f"/var/lib/mongo-work/rs0-{port}"
    logpath = "/var/log/mongo-work/rs0-1.log" if port == 27017 else f"/var/log/mongo-work/rs0-{port}.log"
    subprocess.run([MONGOD, "--replSet", "rs0", "--port", str(port), "--bind_ip", "localhost", "--dbpath", dbpath,
                    "--logpath", logpath, "--fork", "--wiredTigerCacheSizeGB", "0.5"], check=True, capture_output=True)


client = MongoClient(URI, serverSelectionTimeoutMS=30000)
events = client.ojahub.get_collection("courier_scans", write_concern=WriteConcern(w="majority", wtimeout=5000))
events.drop()
time.sleep(1)

print("######## E1  majority write, read from a secondary ########")
log(f"topology: {topology()}")
events.insert_one({"tracking_number": "OJX000245000", "status": "OUT_FOR_DELIVERY", "at": datetime.now(timezone.utc)})
sec = client.ojahub.get_collection("courier_scans", read_preference=ReadPreference.SECONDARY)
log(f"w:majority insert acknowledged; immediate plain read from a secondary -> {sec.count_documents({})} document(s)")
log("   (majority ack = durable on 2 of 3 nodes, NOT 'already applied on the node I happen to read from')")

print("\n######## E1b  read-your-writes on a secondary with a causally consistent session ########")
from pymongo.read_concern import ReadConcern
with client.start_session(causal_consistency=True) as sess:
    coll = client.ojahub.get_collection("courier_scans", write_concern=WriteConcern(w="majority"))
    coll.insert_one({"tracking_number": "OJX000245000", "status": "DELIVERED", "at": datetime.now(timezone.utc)}, session=sess)
    csec = client.ojahub.get_collection("courier_scans", read_preference=ReadPreference.SECONDARY,
                                        read_concern=ReadConcern("majority"))
    log(f"same session, read from a secondary with afterClusterTime -> {csec.count_documents({}, session=sess)} document(s)"
        f" (the secondary waits until it has applied the session's write)")

print("\n######## E2  crash the primary (SIGKILL) and measure the election ########")
primary_port = client.primary[1]
pid = kill(primary_port)
t_kill = time.perf_counter()
log(f"killed PRIMARY localhost:{primary_port} (pid {pid})")
attempt = 0
while True:
    attempt += 1
    try:
        events.insert_one({"tracking_number": "OJX000245001", "status": "IN_TRANSIT", "at": datetime.now(timezone.utc)})
        break
    except PyMongoError as e:
        log(f"write attempt {attempt} failed: {type(e).__name__}")
        time.sleep(0.2)
t_ok = time.perf_counter()
log(f"write succeeded on new primary localhost:{client.primary[1]} after {(t_ok - t_kill):.2f} s "
    f"(election + driver rediscovery; retryable writes hid the failover from the application)")
log(f"topology: {topology()}")
cfg = direct(client.primary[1]).admin.command("replSetGetConfig")["config"]["settings"]
log(f"settings: electionTimeoutMillis={cfg['electionTimeoutMillis']}, heartbeatIntervalMillis={cfg['heartbeatIntervalMillis']}")

print("\n######## E3  restart the crashed node: it rejoins as SECONDARY and catches up ########")
start(primary_port)
for _ in range(60):
    if f"{primary_port}:SECONDARY" in topology():
        break
    time.sleep(0.5)
log(f"topology: {topology()}")
time.sleep(1)
n = direct(primary_port).ojahub.courier_scans.count_documents({})
log(f"documents on the rejoined node (written while it was dead included): {n}")

print("\n######## E4  lose the majority: 2 of 3 members down ########")
victims = [p for p in (27017, 27018, 27019) if p != client.primary[1]]
for v in victims:
    kill(v)
    log(f"killed localhost:{v}")
time.sleep(12)        # > electionTimeout: the lone primary notices it cannot see a majority and steps down
log(f"topology: {topology()}")
fast = MongoClient(URI, serverSelectionTimeoutMS=3000)
try:
    fast.ojahub.get_collection("courier_scans", write_concern=WriteConcern(w="majority", wtimeout=2000)) \
        .insert_one({"tracking_number": "OJX000245002", "status": "DELIVERED"})
    log("write accepted (unexpected)")
except PyMongoError as e:
    log(f"write refused: {type(e).__name__} - no PRIMARY can be elected without a majority (consistency over availability)")
reader = fast.ojahub.get_collection("courier_scans", read_preference=ReadPreference.SECONDARY_PREFERRED)
log(f"read with secondaryPreferred still works -> {reader.count_documents({})} document(s) (possibly stale)")

print("\n######## restore ########")
for v in victims:
    start(v)
for _ in range(60):
    t = topology()
    if "PRIMARY" in t and "DOWN" not in t:
        break
    time.sleep(0.5)
log(f"topology: {topology()}")
client.ojahub.courier_scans.drop()
