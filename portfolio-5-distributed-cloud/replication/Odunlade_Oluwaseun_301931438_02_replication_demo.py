#!/usr/bin/env python3
"""
Portfolio 5 - streaming replication behaviour, measured.

  R2  replication lag: a courier scan written on the primary, how long until the standby sees it?
  R3  the standby is read-only
  R4  consistency vs latency: asynchronous vs synchronous (remote flush) vs remote_apply
      - commit latency on the primary
      - "stale reads": reading the standby immediately after the commit returned
  R5  lag under a bulk write burst (WAL bytes not yet replayed)
"""
import statistics, threading, time
import psycopg2

PRIMARY = "host=localhost port=5432 dbname=seunbaba user=postgres"
STANDBY = "host=localhost port=5433 dbname=seunbaba user=postgres"


def connect(dsn):
    c = psycopg2.connect(dsn)
    c.autocommit = True
    cur = c.cursor()
    cur.execute("SET search_path = seunbaba, public")
    return c, cur


pc, p = connect(PRIMARY)
sc, s = connect(STANDBY)
p.execute("SELECT min(shipment_id) FROM shipment")
SHIP = p.fetchone()[0]
INS = """INSERT INTO shipment_event (shipment_id, event_status, event_location, event_time)
         VALUES (%s, 'IN_TRANSIT', 'replication-probe', now()) RETURNING event_id"""


def hr(t):
    print(f"\n######## {t} ########")


def repl_state():
    p.execute("SELECT application_name, state, sync_state FROM pg_stat_replication")
    return p.fetchall()


# ------------------------------------------------------------------ R2
hr("R2  Replication lag: primary write -> visible on standby (asynchronous, 50 probes)")
lags = []
for _ in range(50):
    p.execute(INS, (SHIP,)); eid = p.fetchone()[0]
    t0 = time.perf_counter()
    while True:
        s.execute("SELECT 1 FROM shipment_event WHERE event_id = %s", (eid,))
        if s.fetchone():
            break
    lags.append((time.perf_counter() - t0) * 1000)
print(f"replication state     : {repl_state()}")
print(f"visible on standby after: median {statistics.median(lags):.2f} ms, p95 {sorted(lags)[int(.95 * len(lags)) - 1]:.2f} ms, max {max(lags):.2f} ms")

# ------------------------------------------------------------------ R3
hr("R3  The standby rejects writes")
try:
    s.execute(INS, (SHIP,))
except psycopg2.Error as e:
    print(f"INSERT on standby -> ERROR {e.pgcode}: {e.pgerror.strip().splitlines()[0]}")
s.execute("SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn()")
print("standby pg_is_in_recovery, last replayed LSN:", s.fetchone())

# ------------------------------------------------------------------ R4
hr("R4  Consistency vs latency: 300 single-row commits per mode")
print(f"{'mode':44} {'sync_state':10} {'mean commit':>12} {'p95 commit':>11} {'stale reads':>12}")
modes = [("asynchronous (synchronous_commit=local)", "", "local"),
         ("synchronous, remote flush (=on)", "standby1", "on"),
         ("synchronous, remote_apply", "standby1", "remote_apply")]
for label, names, sc_level in modes:
    p.execute(f"ALTER SYSTEM SET synchronous_standby_names = '{names}'")
    p.execute("SELECT pg_reload_conf()")
    time.sleep(1.0)
    p.execute(f"SET synchronous_commit = {sc_level}")
    state = repl_state()[0][2]
    lat, stale = [], 0
    for _ in range(300):
        t0 = time.perf_counter()
        p.execute(INS, (SHIP,)); eid = p.fetchone()[0]          # autocommit: INSERT + COMMIT
        lat.append((time.perf_counter() - t0) * 1000)
        s.execute("SELECT 1 FROM shipment_event WHERE event_id = %s", (eid,))   # read-your-write on replica
        if s.fetchone() is None:
            stale += 1
    print(f"{label:44} {state:10} {statistics.mean(lat):9.3f} ms {sorted(lat)[284]:8.3f} ms {stale:>8} /300")
p.execute("ALTER SYSTEM SET synchronous_standby_names = ''")
p.execute("SELECT pg_reload_conf()")
p.execute("SET synchronous_commit = on")

# ------------------------------------------------------------------ R5
hr("R5  Lag during a bulk write burst (2,000,000-row load on the primary)")
samples = []
stop = threading.Event()


def sampler():
    mc, m = connect(PRIMARY)
    t0 = time.perf_counter()
    while not stop.is_set():
        m.execute("""SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), extract(epoch FROM replay_lag) * 1000
                     FROM pg_stat_replication WHERE application_name = 'standby1'""")
        r = m.fetchone()
        if r:
            samples.append((time.perf_counter() - t0, int(r[0]), r[1]))
        time.sleep(0.1)
    mc.close()


th = threading.Thread(target=sampler); th.start()
time.sleep(0.3)
t0 = time.perf_counter()
p.execute("DROP TABLE IF EXISTS repl_load")
p.execute("CREATE TABLE repl_load AS SELECT g AS id, md5(g::text) AS payload FROM generate_series(1, 2000000) g")
load_s = time.perf_counter() - t0
time.sleep(2.0)
stop.set(); th.join()
peak = max(samples, key=lambda x: x[1])
print(f"bulk load took {load_s:.2f} s on the primary")
print(f"peak replay backlog: {peak[1] / 1e6:.1f} MB of WAL at t={peak[0]:.1f}s (replay_lag {peak[2] or 0:.0f} ms)")
for t, b, l in samples[::max(1, len(samples) // 12)]:
    print(f"   t={t:5.1f}s  backlog={b / 1e6:7.2f} MB  replay_lag={(l or 0):7.1f} ms")
print(f"final backlog: {samples[-1][1]} bytes  (standby caught up)")
s.execute("SELECT count(*) FROM repl_load")
print("rows visible on standby:", s.fetchone()[0])

p.execute("DROP TABLE repl_load")
p.execute("DELETE FROM shipment_event WHERE event_location = 'replication-probe'")
print("\nclean-up done (probe rows and bulk table removed on primary, and therefore on standby)")
