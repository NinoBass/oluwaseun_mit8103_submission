#!/usr/bin/env python3
"""
Portfolio 4 - Redis (key-value / data-structure store) for OjaHub.

  R1  Shopping cart          HASH  cart:{customer_id}         field=sku value=qty, 7-day TTL
  R2  Recently viewed        LIST  viewed:{customer_id}        LPUSH + LTRIM (capped at 10)
  R3  Best-seller board      ZSET  bestsellers:{yyyy-mm}       ZINCRBY on every sale, ZREVRANGE to read
  R4  Product page cache     STRING product:{id} (JSON)        cache-aside with 300 s TTL
  R5  Flash-sale counter     STRING flash:stock:{sku}          naive GET/SET vs DECR vs Lua script
"""
import json, statistics, threading, time
import psycopg2, redis

r = redis.Redis(host="localhost", port=6379, decode_responses=True)
pg = psycopg2.connect("host=localhost dbname=ojahub user=postgres")
pg.autocommit = True
cur = pg.cursor()
cur.execute("SET search_path = ojahub, public")
r.flushdb()


def hr(t):
    print(f"\n######## {t} ########")


# ---------------------------------------------------------------- R1
hr("R1  Shopping cart as a HASH with expiry")
key = "cart:1207"
r.hset(key, mapping={"OJH-000100": 1, "OJH-000245": 2})
r.hincrby(key, "OJH-000100", 1)                       # customer taps "+" on the first item
r.expire(key, 7 * 24 * 3600)
print("HGETALL", key, "->", r.hgetall(key))
print("TTL     ", key, "->", r.ttl(key), "seconds (abandoned carts disappear on their own)")

# ---------------------------------------------------------------- R2
hr("R2  Recently viewed products: capped LIST")
for pid in [12, 45, 12, 300, 77, 5, 91, 13, 8, 64, 99, 150, 7]:
    r.lpush("viewed:1207", pid)
    r.ltrim("viewed:1207", 0, 9)
print("LRANGE viewed:1207 0 -1 ->", r.lrange("viewed:1207", 0, -1), f"(length {r.llen('viewed:1207')}, never grows past 10)")

# ---------------------------------------------------------------- R3
hr("R3  Best-sellers leaderboard (Sorted Set) for October 2026")
cur.execute("""SELECT p.sku, oi.quantity FROM order_item oi JOIN customer_order o USING (order_id)
               JOIN product p USING (product_id)
               WHERE o.order_date >= '2026-10-01 00:00+01' AND o.order_date < '2026-11-01 00:00+01'
                 AND o.order_status <> 'CANCELLED'""")
rows = cur.fetchall()
pipe = r.pipeline(transaction=False)
for sku, qty in rows:                                  # in production: one ZINCRBY per sale event
    pipe.zincrby("bestsellers:2026-10", qty, sku)
pipe.execute()
print(f"loaded {len(rows):,} sale lines; ZCARD = {r.zcard('bestsellers:2026-10'):,} products")
print("ZREVRANGE bestsellers:2026-10 0 4 WITHSCORES ->")
for sku, score in r.zrevrange("bestsellers:2026-10", 0, 4, withscores=True):
    print(f"   {sku}  units={int(score)}")
print("ZREVRANK of OJH-000100 ->", r.zrevrank("bestsellers:2026-10", "OJH-000100"))

sql_top = """SELECT p.sku, sum(oi.quantity) u FROM order_item oi JOIN customer_order o USING (order_id)
             JOIN product p USING (product_id)
             WHERE o.order_date >= '2026-10-01 00:00+01' AND o.order_date < '2026-11-01 00:00+01'
               AND o.order_status <> 'CANCELLED' GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 5"""
t_sql, t_r = [], []
for _ in range(20):
    t = time.perf_counter(); cur.execute(sql_top); cur.fetchall(); t_sql.append((time.perf_counter() - t) * 1000)
    t = time.perf_counter(); r.zrevrange("bestsellers:2026-10", 0, 4, withscores=True); t_r.append((time.perf_counter() - t) * 1000)
print(f"top-5 latency: PostgreSQL aggregate {statistics.median(t_sql):.2f} ms  vs  Redis ZREVRANGE {statistics.median(t_r):.3f} ms (median of 20)")

# ---------------------------------------------------------------- R4
hr("R4  Cache-aside for the product detail page (TTL 300 s)")
PRODUCT_SQL = """SELECT p.product_id, p.sku, p.product_name, p.unit_price::text, v.business_name, c.category_name,
                        (SELECT round(avg(rating), 2)::text FROM product_review pr WHERE pr.product_id = p.product_id),
                        (SELECT count(*) FROM product_review pr WHERE pr.product_id = p.product_id),
                        (SELECT sum(qty_on_hand - qty_reserved) FROM inventory i WHERE i.product_id = p.product_id)
                 FROM product p JOIN vendor v USING (vendor_id) JOIN category c USING (category_id)
                 WHERE p.product_id = %s"""
hits = misses = 0


def product_page(pid):
    global hits, misses
    k = f"product:{pid}"
    cached = r.get(k)
    if cached:
        hits += 1
        return json.loads(cached)
    misses += 1
    cur.execute(PRODUCT_SQL, (pid,))
    doc = dict(zip(["id", "sku", "name", "price", "vendor", "category", "avg_rating", "reviews", "available"], cur.fetchone()))
    r.set(k, json.dumps(doc), ex=300)
    return doc


import random
rnd = random.Random(7)
# skewed traffic, like real shoppers: a few hundred products get most page views
popular = [1 + int(8000 * rnd.random() ** 4) for _ in range(10000)]
t_db = []
for pid in popular[:500]:
    t = time.perf_counter(); cur.execute(PRODUCT_SQL, (pid,)); cur.fetchone(); t_db.append((time.perf_counter() - t) * 1000)
t_hit, t_miss = [], []
for pid in popular:
    before = hits
    t = time.perf_counter(); product_page(pid); dt = (time.perf_counter() - t) * 1000
    (t_hit if hits > before else t_miss).append(dt)
print("example cached value:", r.get(f"product:{popular[0]}"))
print(f"requests={len(popular):,}  hits={hits:,}  misses={misses:,}  hit-ratio={hits / len(popular):.1%}"
      f"  -> {hits / len(popular):.0%} of page views never reach PostgreSQL")
print(f"median latency: PostgreSQL query {statistics.median(t_db):.3f} ms | cache hit {statistics.median(t_hit):.3f} ms"
      f" | cache miss (query + SET) {statistics.median(t_miss):.3f} ms")
print("Invalidation rule: when price/stock changes, the writer runs DEL product:{id} after its SQL COMMIT.")

# ---------------------------------------------------------------- R5
hr("R5  Flash sale in Redis: 40 buyers, 25 units (compare Portfolio 3, test D5)")
LUA_BUY = r.register_script("""
local left = tonumber(redis.call('GET', KEYS[1]) or '0')
if left >= tonumber(ARGV[1]) then
  redis.call('DECRBY', KEYS[1], ARGV[1])
  redis.call('SADD', KEYS[2], ARGV[2])
  return 1
end
return 0""")


def run(mode, buyers=40):
    r.set("flash:stock:OJH-FLASH-001", 25)
    r.delete("flash:buyers:OJH-FLASH-001")
    clients = [redis.Redis(host="localhost", port=6379, decode_responses=True) for _ in range(buyers)]
    barrier = threading.Barrier(buyers)
    ok = []

    def naive(i):
        c = clients[i]; barrier.wait()
        left = int(c.get("flash:stock:OJH-FLASH-001"))
        time.sleep(0.005)                                     # app think-time between read and write
        if left >= 1:
            c.set("flash:stock:OJH-FLASH-001", left - 1); ok.append(i)

    def decr(i):
        c = clients[i]; barrier.wait()
        if c.decr("flash:stock:OJH-FLASH-001") >= 0:          # atomic, single-threaded server
            ok.append(i)
        else:
            c.incr("flash:stock:OJH-FLASH-001")              # compensate the overshoot

    def lua(i):
        c = clients[i]; barrier.wait()
        if LUA_BUY(keys=["flash:stock:OJH-FLASH-001", "flash:buyers:OJH-FLASH-001"], args=[1, 1000 + i], client=c) == 1:
            ok.append(i)

    fn = {"naive": naive, "decr": decr, "lua": lua}[mode]
    t0 = time.perf_counter()
    ths = [threading.Thread(target=fn, args=(i,)) for i in range(buyers)]
    [t.start() for t in ths]; [t.join() for t in ths]
    el = (time.perf_counter() - t0) * 1000
    left = int(r.get("flash:stock:OJH-FLASH-001"))
    return len(ok), left, el


for mode, label in (("naive", "GET -> check in app -> SET"), ("decr", "DECR (+ INCR compensation)"),
                    ("lua", "Lua script: check + DECRBY + SADD buyer, atomically")):
    n, left, el = run(mode)
    verdict = "CORRECT" if n + left == 25 and left >= 0 else f"WRONG ({n} sold + {left} left != 25)"
    print(f"{label:52} success={n:>2}  stock left={left:>2}  -> {verdict}  ({el:.0f} ms)")
print("Redis executes each command / script on one thread, so DECR and Lua are atomic without locks.")
print("Design: Redis gates the stampede in milliseconds; only the 25 winners call place_order() in PostgreSQL,")
print("which stays the system of record (Redis here runs without persistence: --save '' --appendonly no).")

hr("Memory footprint")
info = r.info("memory")
print(f"DBSIZE={r.dbsize()} keys  used_memory={info['used_memory_human']}")
