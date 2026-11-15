#!/usr/bin/env python3
"""
Portfolio 3 - multi-session concurrency demonstrations for OjaHub Commerce.

Each demo opens real, separate PostgreSQL connections ("sessions" A, B, ...)
and interleaves their statements in a controlled order, printing a
timestamped timeline. Output is written to ../evidence/Dn_*.txt.

  D1  Lost update on stock: naive read-modify-write vs. SELECT ... FOR UPDATE
      vs. atomic UPDATE vs. REPEATABLE READ (first-updater-wins)
  D2  Non-repeatable read: READ COMMITTED vs. REPEATABLE READ snapshot
  D3  Write skew (purchase-limit rule): REPEATABLE READ allows it,
      SERIALIZABLE (SSI) aborts one transaction -> retry -> rule holds
  D4  Deadlock: opposite lock order -> 40P01; place_order() fixed lock order -> no deadlock
  D5  Flash-sale stress test: 40 concurrent buyers, 25 units
      naive application logic vs. place_order()

Usage:  python3 concurrency_demos.py [D1 D2 ...]      (default: all)
"""
import os, sys, threading, time
import psycopg2
from psycopg2 import errors

HERE = os.path.dirname(os.path.abspath(__file__))
EVID = os.path.join(HERE, "..", "evidence")
DSN = os.environ.get("OJAHUB_DSN", "host=localhost dbname=ojahub user=postgres")
SETUP_SQL = open(os.path.join(HERE, "..", "sql", "00_demo_setup.sql")).read()


class Timeline:
    def __init__(self, title):
        self.t0 = time.perf_counter()
        self.lines = []
        self.lock = threading.Lock()
        self.title = title
        self.say("=" * 78)
        self.say(title)
        self.say("=" * 78)

    def say(self, msg):
        with self.lock:
            print(msg)
            self.lines.append(msg)

    def log(self, who, msg):
        self.say(f"{time.perf_counter() - self.t0:7.3f}s  [{who:^7}]  {msg}")

    def save(self, fname):
        with open(os.path.join(EVID, fname), "w") as fh:
            fh.write("\n".join(self.lines) + "\n")


def session(name, iso="READ COMMITTED"):
    c = psycopg2.connect(DSN, application_name=name)
    c.set_session(isolation_level=iso, autocommit=False)
    cur = c.cursor()
    cur.execute("SET search_path = ojahub, public")
    c.commit()
    return c


def admin():
    c = psycopg2.connect(DSN, application_name="monitor")
    c.autocommit = True
    cur = c.cursor()
    cur.execute("SET search_path = ojahub, public")
    return c


def reset():
    c = admin()
    c.cursor().execute(SETUP_SQL)
    c.close()


def one(cur, sql, args=None):
    cur.execute(sql, args)
    return cur.fetchone()


def flash_id(cur, sku="OJH-FLASH-001"):
    return one(cur, "SELECT product_id FROM product WHERE sku = %s", (sku,))[0]


def stock(cur, pid):
    return one(cur, "SELECT qty_on_hand, qty_reserved FROM inventory WHERE product_id=%s AND warehouse_id=1", (pid,))


def show_blocking(tl, mon):
    cur = mon.cursor()
    cur.execute("""
        SELECT a.application_name, a.pid, a.state, coalesce(a.wait_event_type,'-'), coalesce(a.wait_event,'-'),
               pg_blocking_pids(a.pid), regexp_replace(left(a.query, 55), '\\s+', ' ', 'g')
        FROM pg_stat_activity a
        WHERE a.application_name IN ('A','B','C') ORDER BY 1""")
    tl.log("monitor", "pg_stat_activity snapshot:")
    for r in cur.fetchall():
        tl.log("monitor", f"   {r[0]} pid={r[1]} state={r[2]} wait={r[3]}:{r[4]} blocked_by={r[5]} | {r[6]}")
    cur.execute("""
        SELECT a.application_name, l.locktype, l.mode, l.granted
        FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE a.application_name IN ('A','B') AND l.locktype IN ('transactionid','tuple')
        ORDER BY 1, 2""")
    for r in cur.fetchall():
        tl.log("monitor", f"   pg_locks: {r[0]} {r[1]:<13} {r[2]:<16} granted={r[3]}")


# ---------------------------------------------------------------------------
def d1_lost_update():
    tl = Timeline("D1  LOST UPDATE on inventory.qty_on_hand (two warehouse clerks record a sale)")
    reset()
    mon = admin(); m = mon.cursor(); pid = flash_id(m)

    # --- (a) naive read-modify-write, READ COMMITTED --------------------------------
    tl.say("\n(a) Naive application logic, READ COMMITTED: read value, compute in app, write value back")
    A, B = session("A"), session("B"); a, b = A.cursor(), B.cursor()
    qa = one(a, "SELECT qty_on_hand FROM inventory WHERE product_id=%s AND warehouse_id=1", (pid,))[0]
    tl.log("A", f"SELECT qty_on_hand -> {qa}")
    qb = one(b, "SELECT qty_on_hand FROM inventory WHERE product_id=%s AND warehouse_id=1", (pid,))[0]
    tl.log("B", f"SELECT qty_on_hand -> {qb}")
    a.execute("UPDATE inventory SET qty_on_hand=%s WHERE product_id=%s AND warehouse_id=1", (qa - 1, pid)); A.commit()
    tl.log("A", f"UPDATE qty_on_hand = {qa - 1}; COMMIT")
    b.execute("UPDATE inventory SET qty_on_hand=%s WHERE product_id=%s AND warehouse_id=1", (qb - 1, pid)); B.commit()
    tl.log("B", f"UPDATE qty_on_hand = {qb - 1}; COMMIT")
    final = stock(m, pid)[0]
    tl.log("monitor", f"final qty_on_hand = {final}  (2 units sold, expected {qa - 2})  ==> LOST UPDATE: {qa - 2 != final}")
    A.close(); B.close()

    # --- (b) pessimistic locking: SELECT ... FOR UPDATE --------------------------------
    reset()
    tl.say("\n(b) Fix 1 - pessimistic row lock: SELECT ... FOR UPDATE (READ COMMITTED)")
    A, B = session("A"), session("B"); a, b = A.cursor(), B.cursor()
    qa = one(a, "SELECT qty_on_hand FROM inventory WHERE product_id=%s AND warehouse_id=1 FOR UPDATE", (pid,))[0]
    tl.log("A", f"SELECT ... FOR UPDATE -> {qa}  (row lock acquired)")
    result = {}

    def b_work():
        tl.log("B", "SELECT ... FOR UPDATE  (must wait for A)")
        result["qb"] = one(b, "SELECT qty_on_hand FROM inventory WHERE product_id=%s AND warehouse_id=1 FOR UPDATE", (pid,))[0]
        tl.log("B", f"lock granted, reads {result['qb']}  (A's committed value)")
        b.execute("UPDATE inventory SET qty_on_hand=%s WHERE product_id=%s AND warehouse_id=1", (result["qb"] - 1, pid)); B.commit()
        tl.log("B", f"UPDATE qty_on_hand = {result['qb'] - 1}; COMMIT")
    t = threading.Thread(target=b_work); t.start(); time.sleep(0.6)
    show_blocking(tl, mon)
    a.execute("UPDATE inventory SET qty_on_hand=%s WHERE product_id=%s AND warehouse_id=1", (qa - 1, pid)); A.commit()
    tl.log("A", f"UPDATE qty_on_hand = {qa - 1}; COMMIT  (releases lock)")
    t.join()
    final = stock(m, pid)[0]
    tl.log("monitor", f"final qty_on_hand = {final}  (expected {qa - 2})  ==> correct: {final == qa - 2}")
    A.close(); B.close()

    # --- (c) atomic UPDATE -------------------------------------------------------------
    reset()
    tl.say("\n(c) Fix 2 - let the DBMS do the arithmetic: UPDATE ... SET qty = qty - 1 (READ COMMITTED)")
    A, B = session("A"), session("B"); a, b = A.cursor(), B.cursor()
    start = stock(m, pid)[0]
    a.execute("UPDATE inventory SET qty_on_hand = qty_on_hand - 1 WHERE product_id=%s AND warehouse_id=1", (pid,))
    tl.log("A", "UPDATE qty_on_hand = qty_on_hand - 1  (not yet committed)")

    def b_atomic():
        tl.log("B", "UPDATE qty_on_hand = qty_on_hand - 1  (blocks on A's row lock)")
        b.execute("UPDATE inventory SET qty_on_hand = qty_on_hand - 1 WHERE product_id=%s AND warehouse_id=1", (pid,))
        B.commit()
        tl.log("B", "re-evaluated on A's committed row version; COMMIT")
    t = threading.Thread(target=b_atomic); t.start(); time.sleep(0.4)
    A.commit(); tl.log("A", "COMMIT")
    t.join()
    final = stock(m, pid)[0]
    tl.log("monitor", f"qty_on_hand {start} -> {final}  ==> correct: {final == start - 2}")
    A.close(); B.close()

    # --- (d) REPEATABLE READ: first updater wins --------------------------------------
    reset()
    tl.say("\n(d) Same naive logic under REPEATABLE READ: PostgreSQL detects the conflict instead of losing it")
    A, B = session("A", "REPEATABLE READ"), session("B", "REPEATABLE READ"); a, b = A.cursor(), B.cursor()
    qa = one(a, "SELECT qty_on_hand FROM inventory WHERE product_id=%s AND warehouse_id=1", (pid,))[0]; tl.log("A", f"SELECT -> {qa}")
    qb = one(b, "SELECT qty_on_hand FROM inventory WHERE product_id=%s AND warehouse_id=1", (pid,))[0]; tl.log("B", f"SELECT -> {qb}")
    a.execute("UPDATE inventory SET qty_on_hand=%s WHERE product_id=%s AND warehouse_id=1", (qa - 1, pid)); A.commit()
    tl.log("A", f"UPDATE = {qa - 1}; COMMIT")
    try:
        b.execute("UPDATE inventory SET qty_on_hand=%s WHERE product_id=%s AND warehouse_id=1", (qb - 1, pid)); B.commit()
        tl.log("B", "COMMIT (unexpected)")
    except errors.SerializationFailure as e:
        B.rollback()
        tl.log("B", f"ERROR {e.pgcode}: {e.pgerror.splitlines()[0].replace("ERROR:  ", "")}")
        tl.log("B", "application must ROLLBACK and RETRY the whole transaction")
    tl.log("monitor", f"final qty_on_hand = {stock(m, pid)[0]} (no silent loss)")
    A.close(); B.close(); mon.close()
    tl.save("D1_lost_update.txt")


# ---------------------------------------------------------------------------
def d2_non_repeatable_read():
    tl = Timeline("D2  NON-REPEATABLE READ: finance reconciliation reads stock value twice while a restock commits")
    for iso in ("READ COMMITTED", "REPEATABLE READ"):
        reset()
        tl.say(f"\nReport session isolation = {iso}")
        R, W = session("A", iso), session("B"); r, w = R.cursor(), W.cursor()
        q = """SELECT sum(i.qty_on_hand * p.unit_price) FROM inventory i JOIN product p USING (product_id)
               WHERE p.sku LIKE 'OJH-FLASH-%'"""
        v1 = one(r, q)[0]; tl.log("A", f"stock value (1st read) = NGN {v1:,.2f}")
        w.execute("""UPDATE inventory SET qty_on_hand = qty_on_hand + 10
                     WHERE product_id IN (SELECT product_id FROM product WHERE sku LIKE 'OJH-FLASH-%')""")
        W.commit(); tl.log("B", "restock +10 units of each flash product; COMMIT")
        v2 = one(r, q)[0]; tl.log("A", f"stock value (2nd read) = NGN {v2:,.2f}")
        tl.log("A", "==> NON-REPEATABLE READ (values differ inside one transaction)" if v1 != v2
               else "==> consistent snapshot: both reads see the same data")
        R.commit(); R.close(); W.close()
    tl.save("D2_non_repeatable_read.txt")


# ---------------------------------------------------------------------------
def d3_write_skew():
    tl = Timeline("D3  WRITE SKEW: 'max 2 flash-sale tickets per customer' checked by application code")
    tl.say("Customer 1207 already holds 1 ticket and taps 'Join flash sale' on phone (A) and laptop (B) at the same time.")
    count_sql = "SELECT count(*) FROM flash_sale_ticket WHERE customer_id = 1207 AND product_id = %s"
    ins_sql = "INSERT INTO flash_sale_ticket (customer_id, product_id) VALUES (1207, %s)"

    def attempt(cur, conn, who, pid):
        n = one(cur, count_sql, (pid,))[0]
        tl.log(who, f"SELECT count(*) -> {n}  (limit is 2)")
        if n >= 2:
            conn.rollback(); tl.log(who, "limit reached -> request refused"); return False
        cur.execute(ins_sql, (pid,)); tl.log(who, "INSERT ticket")
        return True

    for iso in ("REPEATABLE READ", "SERIALIZABLE"):
        reset()
        mon = admin(); m = mon.cursor(); pid = flash_id(m)
        m.execute(ins_sql, (pid,))
        tl.say(f"\nIsolation = {iso}")
        A, B = session("A", iso), session("B", iso); a, b = A.cursor(), B.cursor()
        attempt(a, A, "A", pid)
        attempt(b, B, "B", pid)
        A.commit(); tl.log("A", "COMMIT ok")
        try:
            B.commit(); tl.log("B", "COMMIT ok")
        except errors.SerializationFailure as e:
            B.rollback()
            tl.log("B", f"COMMIT failed {e.pgcode}: {e.pgerror.splitlines()[0].replace("ERROR:  ", "")}")
            tl.log("B", f"   DETAIL: {[l for l in e.pgerror.splitlines() if 'DETAIL' in l][0].split('DETAIL:')[1].strip()}")
            tl.log("B", "retrying whole transaction ...")
            B2 = session("B", iso); b2 = B2.cursor()
            if attempt(b2, B2, "B", pid):
                B2.commit()
            B2.close()
        total = one(m, count_sql, (pid,))[0]
        tl.log("monitor", f"tickets held by customer 1207 = {total}  ==> rule {'VIOLATED' if total > 2 else 'respected'}")
        A.close(); B.close(); mon.close()
    tl.save("D3_write_skew.txt")


# ---------------------------------------------------------------------------
def d4_deadlock():
    tl = Timeline("D4  DEADLOCK: two staff adjust two stock rows in opposite order")
    reset()
    mon = admin(); m = mon.cursor()
    p1, p2 = flash_id(m, "OJH-FLASH-001"), flash_id(m, "OJH-FLASH-002")
    upd = "UPDATE inventory SET qty_on_hand = qty_on_hand + 1 WHERE product_id=%s AND warehouse_id=1"
    A, B = session("A"), session("B"); a, b = A.cursor(), B.cursor()
    a.execute(upd, (p1,)); tl.log("A", "locks FLASH-001")
    b.execute(upd, (p2,)); tl.log("B", "locks FLASH-002")
    outcome = {}

    def run(who, cur, conn, pid, label):
        tl.log(who, f"wants {label} ...")
        try:
            cur.execute(upd, (pid,)); conn.commit(); outcome[who] = "COMMIT"
            tl.log(who, f"got {label}; COMMIT")
        except errors.DeadlockDetected as e:
            conn.rollback(); outcome[who] = "40P01"
            tl.log(who, f"ERROR {e.pgcode}: {e.pgerror.splitlines()[0].replace("ERROR:  ", "")}")
            tl.log(who, "   " + [l for l in e.pgerror.splitlines() if l.startswith("DETAIL")][0])
    ta = threading.Thread(target=run, args=("A", a, A, p2, "FLASH-002")); ta.start(); time.sleep(0.3)
    tb = threading.Thread(target=run, args=("B", b, B, p1, "FLASH-001")); tb.start()
    ta.join(); tb.join()
    tl.log("monitor", f"outcome: {outcome}  (deadlock_timeout = 1s, one victim chosen)")
    A.close(); B.close()

    tl.say("\nFix: place_order() locks inventory rows ORDER BY product_id, whatever order the basket lists them in")
    reset()
    A, B = session("A"), session("B"); a, b = A.cursor(), B.cursor()
    p1, p2 = flash_id(m, "OJH-FLASH-001"), flash_id(m, "OJH-FLASH-002")
    basket_a = f'[{{"product_id": {p1}, "qty": 1}}, {{"product_id": {p2}, "qty": 1}}]'
    basket_b = f'[{{"product_id": {p2}, "qty": 1}}, {{"product_id": {p1}, "qty": 1}}]'
    oa = one(a, "SELECT place_order(1207, %s::jsonb)", (basket_a,))[0]
    tl.log("A", f"place_order(basket FLASH-001, FLASH-002) -> order {oa}, transaction still open")

    def b_order():
        tl.log("B", "place_order(basket FLASH-002, FLASH-001) ...")
        ob = one(b, "SELECT place_order(50, %s::jsonb)", (basket_b,))[0]; B.commit()
        tl.log("B", f"-> order {ob}; COMMIT (waited, no deadlock)")
    t = threading.Thread(target=b_order); t.start(); time.sleep(1.5)
    tl.log("monitor", "1.5 s later (longer than deadlock_timeout): B is simply queued behind A")
    show_blocking(tl, mon)
    A.commit(); tl.log("A", "COMMIT")
    t.join()
    A.close(); B.close(); mon.close()
    tl.save("D4_deadlock.txt")


# ---------------------------------------------------------------------------
def d5_flash_sale_stress(buyers=40):
    tl = Timeline(f"D5  FLASH-SALE STRESS TEST: {buyers} customers press 'Buy' at the same instant, 25 phones in stock")
    mon = admin(); m = mon.cursor()
    m.execute("""SELECT c.customer_id FROM customer c JOIN customer_address a ON a.customer_id=c.customer_id AND a.is_default
                 WHERE c.account_status='ACTIVE' ORDER BY c.customer_id LIMIT %s""", (buyers,))
    customers = [r[0] for r in m.fetchall()]

    def run(mode):
        reset()
        pid = flash_id(m)
        barrier = threading.Barrier(buyers)
        ok, refused, errs = [], [], []
        conns = [session(f"buyer{i}") for i in range(buyers)]

        def naive(i):
            c = conns[i]; cur = c.cursor(); barrier.wait()
            on_hand, reserved = stock(cur, pid)
            time.sleep(0.005)                          # app-server think time (validation, pricing ...)
            if on_hand - reserved >= 1:
                cur.execute("UPDATE inventory SET qty_reserved=%s WHERE product_id=%s AND warehouse_id=1",
                            (reserved + 1, pid))
                c.commit(); ok.append(i)
            else:
                c.rollback(); refused.append(i)

        def safe(i):
            c = conns[i]; cur = c.cursor(); barrier.wait()
            try:
                cur.execute("SELECT place_order(%s, %s::jsonb)", (customers[i], f'[{{"product_id": {pid}, "qty": 1}}]'))
                c.commit(); ok.append(i)
            except psycopg2.Error as e:
                c.rollback()
                (refused if e.pgcode == "OJ003" else errs).append((i, e.pgcode))

        t0 = time.perf_counter()
        ths = [threading.Thread(target=naive if mode == "naive" else safe, args=(i,)) for i in range(buyers)]
        [t.start() for t in ths]; [t.join() for t in ths]
        elapsed = time.perf_counter() - t0
        [c.close() for c in conns]
        on_hand, reserved = stock(m, pid)
        orders = one(m, """SELECT count(DISTINCT oi.order_id), coalesce(sum(oi.quantity),0) FROM order_item oi
                           WHERE oi.product_id = %s""", (pid,))
        return ok, refused, errs, on_hand, reserved, orders, elapsed

    for mode, label in (("naive", "Naive: SELECT stock, check in app, UPDATE qty_reserved = <value read> (READ COMMITTED)"),
                        ("safe", "place_order(): SELECT ... FOR UPDATE + CHECK constraints, one transaction per buyer")):
        ok, refused, errs, on_hand, reserved, orders, el = run(mode)
        tl.say(f"\n{label}")
        tl.say(f"   buyers told 'success'      : {len(ok)}")
        tl.say(f"   buyers told 'out of stock' : {len(refused)}")
        tl.say(f"   other errors               : {len(errs)} {errs[:3]}")
        tl.say(f"   inventory after            : qty_on_hand={on_hand}, qty_reserved={reserved}, available={on_hand - reserved}")
        if mode == "naive":
            tl.say(f"   ==> {len(ok)} confirmations but only {reserved} unit(s) recorded as reserved: "
                   f"{len(ok) - reserved} lost updates, {max(0, len(ok) - 25)} phones promised that do not exist")
        else:
            tl.say(f"   orders created             : {orders[0]} orders, {orders[1]} units")
            tl.say(f"   ==> invariant holds: success == reserved == orders == 25 -> "
                   f"{len(ok) == reserved == orders[1] == 25}")
        tl.say(f"   wall-clock                 : {el * 1000:.0f} ms")
    mon.close()
    tl.save("D5_flash_sale_stress.txt")


DEMOS = {"D1": d1_lost_update, "D2": d2_non_repeatable_read, "D3": d3_write_skew,
         "D4": d4_deadlock, "D5": d5_flash_sale_stress}

if __name__ == "__main__":
    for name in (sys.argv[1:] or list(DEMOS)):
        DEMOS[name]()
        print()
