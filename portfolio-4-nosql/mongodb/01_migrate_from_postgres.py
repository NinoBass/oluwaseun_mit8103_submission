#!/usr/bin/env python3
"""
Portfolio 4 - migrate OjaHub data from PostgreSQL (Portfolio 1) into MongoDB 8.0.

Document model (see ../README.md for the reasoning):
  products   one document per product. Category-specific "attributes" sub-document
             (RAM for phones, sizes for shoes, weight for rice ...) that would be
             awkward as relational columns. Computed rating summary and the 3 most
             recent reviews are embedded (computed + subset patterns).
  customers  customer with addresses EMBEDDED (always read together, bounded size).
  orders     order with line items, payment attempts, shipment AND tracking events
             EMBEDDED: the order page / tracking page is served by ONE read.
             Product name/SKU are copied into each line (snapshot at purchase time).
  reviews    full review history in its own collection (unbounded growth).

Orders from 2026-01-01 onward are migrated (the "hot" operational window).
"""
import random, time
from decimal import Decimal
import psycopg2, psycopg2.extras
from pymongo import MongoClient, ASCENDING, DESCENDING, TEXT
from bson.decimal128 import Decimal128

PG = "host=localhost dbname=ojahub user=postgres"
MONGO = "mongodb://localhost:27017/?replicaSet=rs0"
SINCE = "2026-01-01 00:00+01"


def d128(x):
    return Decimal128(str(x)) if x is not None else None


def attributes(leaf, pid, name):
    """Category-specific attributes, deterministic per product."""
    r = random.Random(pid)
    if leaf in ("Smartphones", "Tablets"):
        return {"ram_gb": r.choice([4, 6, 8, 12]), "storage_gb": int(next((s for s in ("512", "256", "128", "64") if s + "GB" in name), r.choice(["64", "128", "256"]))),
                "screen_in": r.choice([6.1, 6.6, 6.78, 8.7, 10.4]), "battery_mah": r.choice([4000, 5000, 6000, 7040]),
                "dual_sim": leaf == "Smartphones", "network": r.choice(["4G", "5G"]), "colours": r.sample(["Black", "Blue", "Gold", "Green", "White"], 2)}
    if leaf == "Laptops":
        return {"cpu": r.choice(["Intel Core i5-1235U", "Intel Core i7-1255U", "AMD Ryzen 5 7520U"]), "ram_gb": r.choice([8, 16, 32]),
                "ssd_gb": r.choice([256, 512, 1024]), "screen_in": r.choice([14, 15.6]), "os": r.choice(["Windows 11", "FreeDOS", "ChromeOS"])}
    if leaf == "Televisions":
        return {"screen_in": r.choice([32, 43, 50, 55, 65]), "resolution": r.choice(["HD", "FHD", "4K UHD"]), "smart": r.random() > .2,
                "panel": r.choice(["LED", "QLED"]), "voltage": "220-240V"}
    if leaf == "Power & Solar":
        return {"rated_power": r.choice(["1.5kVA", "3.5kVA", "5kVA", "300W", "450W"]), "type": r.choice(["inverter", "solar panel", "generator", "stabiliser"]),
                "warranty_months": r.choice([12, 24, 60])}
    if leaf in ("Men's Clothing", "Women's Clothing"):
        return {"sizes": r.sample(["S", "M", "L", "XL", "XXL"], 3), "colours": r.sample(["Black", "Navy", "Wine", "Ankara print", "White"], 2),
                "material": r.choice(["Cotton", "Ankara wax print", "Linen", "Polyester"]), "made_in_nigeria": r.random() > .5}
    if leaf == "Footwear":
        return {"sizes_eu": sorted(r.sample(range(38, 47), 5)), "material": r.choice(["Leather", "Canvas", "Synthetic"]), "made_in_nigeria": "Aba" in name}
    if leaf in ("Beverages", "Food Cupboard"):
        return {"net_weight_kg": r.choice([0.4, 0.9, 1, 5, 10, 25]), "pack_size": r.choice([1, 6, 12, 24]), "shelf_life_months": r.choice([6, 12, 18]),
                "halal": r.random() > .3, "nafdac_no": f"A1-{r.randint(1000, 9999)}"}
    if leaf in ("Skin Care", "Hair Care", "Fragrances"):
        return {"volume_ml": r.choice([50, 100, 200, 400, 500]), "skin_type": r.choice(["all", "dry", "oily", "sensitive"]),
                "nafdac_no": f"02-{r.randint(1000, 9999)}"}
    if leaf in ("Small Appliances", "Cookware"):
        return {"power_w": r.choice([800, 1200, 1500, 2000]), "capacity_l": r.choice([1.5, 1.7, 4.2, 5.5]), "warranty_months": r.choice([6, 12, 24])}
    if leaf in ("Diapering", "Baby Feeding"):
        return {"age_range": r.choice(["0-6 months", "6-12 months", "1-3 years"]), "count": r.choice([30, 52, 60, 80])}
    return {"warranty_months": r.choice([0, 6, 12])}


def main():
    t0 = time.time()
    pg = psycopg2.connect(PG)
    cur = pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SET search_path = ojahub, public")
    mc = MongoClient(MONGO)
    mc.drop_database("ojahub")
    db = mc.ojahub

    # ---------------- schema validation (MongoDB is schema-flexible, not schema-less) -------
    db.create_collection("orders", validator={"$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "customer", "status", "order_date", "items", "totals"],
        "properties": {
            "status": {"enum": ["PENDING", "PAID", "SHIPPED", "DELIVERED", "CANCELLED", "REFUNDED"]},
            "order_date": {"bsonType": "date"},
            "items": {"bsonType": "array", "minItems": 1, "items": {
                "bsonType": "object", "required": ["product_id", "qty", "unit_price"],
                "properties": {"qty": {"bsonType": "int", "minimum": 1, "maximum": 100},
                               "unit_price": {"bsonType": "decimal"}}}},
            "totals": {"bsonType": "object", "required": ["total"],
                       "properties": {"total": {"bsonType": "decimal"}}}}}},
        validationAction="error")
    db.create_collection("products", validator={"$jsonSchema": {
        "bsonType": "object", "required": ["_id", "sku", "name", "price", "category"],
        "properties": {"price": {"bsonType": "decimal"}, "sku": {"bsonType": "string", "pattern": "^OJH-"}}}})

    # ---------------- products ----------------
    cur.execute("""
        SELECT p.product_id, p.sku, p.product_name, p.description, p.unit_price, p.weight_kg, p.is_active, p.created_at,
               leaf.category_name AS leaf, parent.category_name AS parent, v.vendor_id, v.business_name,
               coalesce((SELECT jsonb_object_agg(warehouse_id, qty_on_hand - qty_reserved) FROM inventory i
                          WHERE i.product_id = p.product_id), '{}'::jsonb) AS stock
        FROM product p JOIN category leaf ON leaf.category_id = p.category_id
        LEFT JOIN category parent ON parent.category_id = leaf.parent_category_id
        JOIN vendor v ON v.vendor_id = p.vendor_id""")
    products = {}
    for r in cur.fetchall():
        products[r["product_id"]] = {
            "_id": r["product_id"], "sku": r["sku"], "name": r["product_name"], "description": r["description"],
            "price": d128(r["unit_price"]), "weight_kg": float(r["weight_kg"]) if r["weight_kg"] else None,
            "active": r["is_active"], "created_at": r["created_at"],
            "category": {"top": r["parent"], "leaf": r["leaf"], "path": f"{r['parent']} > {r['leaf']}"},
            "vendor": {"vendor_id": r["vendor_id"], "name": r["business_name"]},
            "attributes": attributes(r["leaf"], r["product_id"], r["product_name"]),
            "stock": {f"wh{k}": v for k, v in r["stock"].items()},
            "rating": {"count": 0, "avg": None}, "recent_reviews": []}
    cur.execute("""SELECT product_id, count(*) AS n, round(avg(rating), 2) AS avg FROM product_review GROUP BY 1""")
    for r in cur.fetchall():
        products[r["product_id"]]["rating"] = {"count": r["n"], "avg": float(r["avg"])}
    cur.execute("""SELECT product_id, customer_id, rating, review_text, created_at FROM (
                     SELECT r.*, row_number() OVER (PARTITION BY product_id ORDER BY created_at DESC) rn FROM product_review r) x
                   WHERE rn <= 3""")
    for r in cur.fetchall():
        products[r["product_id"]]["recent_reviews"].append(
            {"customer_id": r["customer_id"], "rating": r["rating"], "text": r["review_text"], "at": r["created_at"]})
    db.products.insert_many(products.values())

    # ---------------- reviews (separate: unbounded) ----------------
    cur.execute("SELECT review_id, product_id, customer_id, rating, review_text, created_at FROM product_review")
    db.reviews.insert_many([{"_id": r["review_id"], "product_id": r["product_id"], "customer_id": r["customer_id"],
                             "rating": r["rating"], "text": r["review_text"], "created_at": r["created_at"]} for r in cur.fetchall()])

    # ---------------- customers with embedded addresses ----------------
    cur.execute("""SELECT c.customer_id, c.email, c.phone, c.first_name, c.last_name, c.account_status, c.created_at,
                          jsonb_agg(jsonb_build_object('address_id', a.address_id, 'label', a.label, 'street', a.street_line,
                                    'city', a.city, 'state_code', a.state_code, 'default', a.is_default) ORDER BY a.address_id) AS addr
                   FROM customer c JOIN customer_address a USING (customer_id) GROUP BY c.customer_id""")
    db.customers.insert_many([{"_id": r["customer_id"], "email": r["email"].lower(), "phone": r["phone"],
                               "name": {"first": r["first_name"], "last": r["last_name"]}, "status": r["account_status"],
                               "created_at": r["created_at"], "addresses": r["addr"]} for r in cur.fetchall()])

    # ---------------- orders (aggregate root with embedded children) ----------------
    cur.execute("""SELECT o.order_id, o.customer_id, c.first_name || ' ' || c.last_name AS cname, c.email, o.order_status,
                          o.order_date, o.coupon_code, o.subtotal, o.discount_amount, o.delivery_fee, o.total_amount,
                          a.city, a.state_code, sr.state_name, sr.geo_zone
                   FROM customer_order o JOIN customer c USING (customer_id)
                   JOIN customer_address a ON a.address_id = o.shipping_address_id
                   JOIN state_region sr ON sr.state_code = a.state_code
                   WHERE o.order_date >= %s""", (SINCE,))
    orders = {}
    for r in cur.fetchall():
        orders[r["order_id"]] = {
            "_id": r["order_id"],
            "customer": {"customer_id": r["customer_id"], "name": r["cname"], "email": r["email"].lower()},
            "ship_to": {"city": r["city"], "state_code": r["state_code"], "state": r["state_name"], "geo_zone": r["geo_zone"]},
            "status": r["order_status"], "order_date": r["order_date"], "coupon": r["coupon_code"],
            "totals": {"subtotal": d128(r["subtotal"]), "discount": d128(r["discount_amount"]),
                       "delivery_fee": d128(r["delivery_fee"]), "total": d128(r["total_amount"])},
            "items": [], "payments": [], "shipment": None}
    cur.execute("""SELECT oi.order_id, oi.line_no, oi.product_id, p.sku, p.product_name, oi.quantity, oi.unit_price, oi.warehouse_id
                   FROM order_item oi JOIN product p USING (product_id) JOIN customer_order o USING (order_id)
                   WHERE o.order_date >= %s ORDER BY oi.order_id, oi.line_no""", (SINCE,))
    for r in cur.fetchall():
        orders[r["order_id"]]["items"].append({"line_no": r["line_no"], "product_id": r["product_id"], "sku": r["sku"],
                                               "name": r["product_name"], "qty": r["quantity"],
                                               "unit_price": d128(r["unit_price"]), "warehouse": f"wh{r['warehouse_id']}"})
    cur.execute("""SELECT pm.* FROM payment pm JOIN customer_order o USING (order_id) WHERE o.order_date >= %s
                   ORDER BY pm.payment_id""", (SINCE,))
    for r in cur.fetchall():
        orders[r["order_id"]]["payments"].append({"method": r["payment_method"], "amount": d128(r["amount"]),
                                                  "status": r["payment_status"], "gateway_ref": r["gateway_ref"],
                                                  "initiated_at": r["initiated_at"], "settled_at": r["settled_at"]})
    cur.execute("""SELECT s.*, w.warehouse_name FROM shipment s JOIN warehouse w USING (warehouse_id)
                   JOIN customer_order o USING (order_id) WHERE o.order_date >= %s""", (SINCE,))
    ship_by_id = {}
    for r in cur.fetchall():
        sh = {"courier": r["courier_name"], "tracking_number": r["tracking_number"], "status": r["shipment_status"],
              "from_warehouse": r["warehouse_name"], "shipped_at": r["shipped_at"], "delivered_at": r["delivered_at"], "events": []}
        orders[r["order_id"]]["shipment"] = sh
        ship_by_id[r["shipment_id"]] = sh
    cur.execute("""SELECT e.shipment_id, e.event_status, e.event_location, e.event_time FROM shipment_event e
                   JOIN shipment s USING (shipment_id) JOIN customer_order o USING (order_id)
                   WHERE o.order_date >= %s ORDER BY e.shipment_id, e.event_time""", (SINCE,))
    for r in cur.fetchall():
        ship_by_id[r["shipment_id"]]["events"].append({"status": r["event_status"], "location": r["event_location"], "at": r["event_time"]})
    docs = list(orders.values())
    for i in range(0, len(docs), 5000):
        db.orders.insert_many(docs[i:i + 5000], ordered=False)

    # ---------------- indexes ----------------
    db.orders.create_index([("customer.customer_id", ASCENDING), ("order_date", DESCENDING)], name="ix_customer_date")
    db.orders.create_index("shipment.tracking_number", unique=True, sparse=True, name="ux_tracking")
    db.orders.create_index([("status", ASCENDING), ("order_date", ASCENDING)], name="ix_status_date",
                           partialFilterExpression={"status": "PAID"})
    db.products.create_index([("category.leaf", ASCENDING), ("attributes.ram_gb", ASCENDING), ("price", ASCENDING)], name="ix_leaf_ram_price")
    db.products.create_index([("attributes.$**", ASCENDING)], name="wix_attributes")
    db.products.create_index([("name", TEXT), ("description", TEXT)], weights={"name": 10, "description": 1}, name="tx_name_desc")
    db.products.create_index("sku", unique=True, name="ux_sku")
    db.reviews.create_index([("product_id", ASCENDING), ("created_at", DESCENDING)], name="ix_product_date")
    db.customers.create_index("email", unique=True, name="ux_email")

    for c in ("products", "reviews", "customers", "orders"):
        st = db.command("collStats", c)
        print(f"{c:10} docs={st['count']:>8,}  avgObjSize={st['avgObjSize']:>6,} B  storage={st['storageSize'] / 1e6:6.1f} MB  "
              f"indexes={st['nindexes']}")
    print(f"migration finished in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
