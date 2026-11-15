#!/usr/bin/env python3
"""Verifies the PostgreSQL -> MongoDB migration: monthly revenue per geo-zone
(Sep-Oct 2026) computed by SQL (Portfolio 2, Q3 logic) and by a MongoDB
aggregation pipeline must be identical, to the kobo."""
from decimal import Decimal
import psycopg2
from pymongo import MongoClient
from datetime import datetime, timezone

pg = psycopg2.connect("host=localhost dbname=ojahub user=postgres").cursor()
pg.execute("""
    SELECT sr.geo_zone, to_char(date_trunc('month', o.order_date), 'YYYY-MM'), count(*), sum(o.total_amount)
    FROM ojahub.customer_order o
    JOIN ojahub.customer_address a ON a.address_id = o.shipping_address_id
    JOIN ojahub.state_region sr ON sr.state_code = a.state_code
    WHERE o.order_date >= '2026-09-01 00:00+01' AND o.order_date < '2026-11-01 00:00+01'
      AND o.order_status IN ('PAID','SHIPPED','DELIVERED')
    GROUP BY 1, 2""")
sql = {(z, m): (n, Decimal(r)) for z, m, n, r in pg.fetchall()}

db = MongoClient("mongodb://localhost:27017/?replicaSet=rs0").ojahub
mongo = {}
for r in db.orders.aggregate([
        {"$match": {"order_date": {"$gte": datetime(2026, 8, 31, 23, tzinfo=timezone.utc),
                                   "$lt": datetime(2026, 10, 31, 23, tzinfo=timezone.utc)},
                    "status": {"$in": ["PAID", "SHIPPED", "DELIVERED"]}}},
        {"$group": {"_id": {"z": "$ship_to.geo_zone",
                            "m": {"$dateToString": {"format": "%Y-%m", "date": "$order_date", "timezone": "Africa/Lagos"}}},
                    "n": {"$sum": 1}, "rev": {"$sum": "$totals.total"}}}]):
    mongo[(r["_id"]["z"], r["_id"]["m"])] = (r["n"], r["rev"].to_decimal())

print("Cross-check: PostgreSQL (SQL GROUP BY) vs MongoDB (aggregation pipeline), Sep-Oct 2026, Lagos time")
print(f"{'geo_zone':14} {'month':8} {'SQL orders':>10} {'Mongo orders':>12} {'SQL revenue NGN':>18} {'Mongo revenue NGN':>18}  match")
ok = True
for k in sorted(sql):
    s, m = sql[k], mongo.get(k, (None, None))
    same = s == m
    ok &= same
    print(f"{k[0]:14} {k[1]:8} {s[0]:>10} {m[0]:>12} {s[1]:>18,.2f} {m[1]:>18,.2f}  {'YES' if same else 'NO'}")
print(f"\n{len(sql)} rows compared, keys only in MongoDB: {len(set(mongo) - set(sql))}, all identical: {ok}")
