-- =====================================================================
-- Portfolio 1 - 03_seed_data.sql
-- Deterministic synthetic data generator for SeunBaba Commerce.
-- All data is fictitious. setseed() makes every run produce the same
-- data so that query plans and timings in Portfolio 2 are repeatable.
--
-- Approximate volumes produced:
--   customers 50 000 | addresses ~65 000 | vendors 150 | products 8 000
--   orders 300 000   | order lines ~750 000 | payments ~300 000
--   shipments ~265 000 | shipment events ~1 000 000 | reviews ~60 000
-- =====================================================================
SET search_path = seunbaba, public;
SELECT setseed(0.8103);

-- ---------------------------------------------------------------------
-- Helper: weighted list of delivery cities (Lagos dominates demand)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE city_pool (city TEXT, state_code CHAR(2), weight INT);
INSERT INTO city_pool VALUES
 ('Ikeja','LA',9),('Lekki','LA',8),('Yaba','LA',5),('Surulere','LA',5),('Ikorodu','LA',4),('Ajah','LA',4),
 ('Abuja','FC',12),('Port Harcourt','RI',8),('Ibadan','OY',6),('Kano','KN',5),('Benin City','ED',4),
 ('Enugu','EN',4),('Abeokuta','OG',3),('Kaduna','KD',3),('Uyo','AK',2),('Owerri','IM',2),('Warri','DE',3),
 ('Onitsha','AN',3),('Ilorin','KW',2),('Jos','PL',2),('Calabar','CR',2),('Akure','ON',2),('Osogbo','OS',1),
 ('Aba','AB',2),('Maiduguri','BO',1),('Sokoto','SO',1),('Makurdi','BE',1),('Lokoja','KO',1),('Bauchi','BA',1),
 ('Yenagoa','BY',1),('Ado-Ekiti','EK',1),('Lafia','NA',1),('Minna','NI',1),('Katsina','KT',1),('Gombe','GO',1);

CREATE TEMP TABLE city_cdf AS
SELECT city, state_code,
       (sum(weight) OVER (ORDER BY city ROWS UNBOUNDED PRECEDING))::numeric / sum(weight) OVER () AS cum_hi
FROM city_pool;

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
INSERT INTO customer (email, phone, first_name, last_name, date_of_birth, account_status, created_at)
SELECT lower(fn) || '.' || lower(ln) || g || '@' ||
         (ARRAY['gmail.com','yahoo.com','outlook.com','seunbaba.ng','hotmail.com'])[1 + (g % 5)],
       '+234' || (ARRAY['803','806','813','816','703','706','810','814','903','906',
                        '802','808','812','701','902','805','807','815','905'])[1 + (g % 19)]
              || lpad(g::text, 7, '0'),
       fn, ln,
       DATE '1965-01-01' + (random() * 15000)::int,
       CASE WHEN random() < 0.97 THEN 'ACTIVE' WHEN random() < 0.6 THEN 'SUSPENDED' ELSE 'CLOSED' END,
       TIMESTAMPTZ '2023-06-01 00:00+01' + random() * INTERVAL '1200 days'
FROM (
  SELECT g,
    (ARRAY['Adebayo','Chinedu','Aisha','Ngozi','Emeka','Fatima','Tunde','Funmilayo','Ibrahim','Chiamaka',
           'Yusuf','Blessing','Kelechi','Zainab','Olumide','Amaka','Musa','Temitope','Ifeanyi','Hadiza',
           'Segun','Nneka','Abdullahi','Bukola','Obinna','Halima','Kunle','Ebere','Sani','Damilola',
           'Uche','Maryam','Femi','Adaeze','Bello','Yetunde','Chukwudi','Hauwa','Gbenga','Ifeoma',
           'Usman','Toyin','Nnamdi','Rukayat','Efosa','Osas','Ekaette','Tamuno','Ebiere','Kehinde'])
           [1 + floor(random() * 50)::int] AS fn,
    (ARRAY['Adeyemi','Okafor','Bello','Okonkwo','Abubakar','Ogunleye','Eze','Mohammed','Balogun','Nwosu',
           'Ibrahim','Adebayo','Obi','Lawal','Chukwu','Akinola','Danjuma','Okeke','Olawale','Ugwu',
           'Suleiman','Afolabi','Nwachukwu','Yakubu','Oyelaran','Igwe','Aliyu','Ojo','Anyanwu','Garba',
           'Ekpo','Etim','Idowu','Osagie','Omoregie','Briggs','Amadi','Fashola','Ikenna','Tijani'])
           [1 + floor(random() * 40)::int] AS ln
  FROM generate_series(1, 50000) AS g
) s;

-- One default address per customer, ~30 % have an extra OFFICE address.
INSERT INTO customer_address (customer_id, label, street_line, city, state_code, is_default)
SELECT c.customer_id, 'HOME',
       (1 + floor(random() * 120))::int || ' ' ||
       (ARRAY['Allen Avenue','Adeola Odeku Street','Admiralty Way','Herbert Macaulay Way','Aminu Kano Crescent',
              'Ogui Road','Aba Road','Ring Road','Ahmadu Bello Way','Murtala Mohammed Way','Awolowo Road',
              'Opebi Road','Isaac John Street','Ozumba Mbadiwe Avenue','Wuse Zone 4 Street'])[1 + floor(random()*15)::int],
       cc.city, cc.state_code, true
FROM customer c
CROSS JOIN LATERAL (SELECT random() + c.customer_id * 0 AS r OFFSET 0) rr
CROSS JOIN LATERAL (SELECT city, state_code FROM city_cdf WHERE cum_hi >= rr.r ORDER BY cum_hi LIMIT 1) cc;

INSERT INTO customer_address (customer_id, label, street_line, city, state_code, is_default)
SELECT c.customer_id, 'OFFICE',
       'Plot ' || (1 + floor(random() * 400))::int || ', Central Business District',
       cc.city, cc.state_code, false
FROM customer c
CROSS JOIN LATERAL (SELECT random() + c.customer_id * 0 AS r OFFSET 0) rr
CROSS JOIN LATERAL (SELECT city, state_code FROM city_cdf WHERE cum_hi >= rr.r ORDER BY cum_hi LIMIT 1) cc
WHERE c.customer_id % 10 < 3;

-- ---------------------------------------------------------------------
-- Vendors
-- ---------------------------------------------------------------------
INSERT INTO vendor (business_name, cac_rc_number, contact_email, state_code, commission_pct, onboarded_on, is_active)
SELECT (ARRAY['Mainland','Island','Eko','Arewa','Naija','Royal','Prime','Delta','Sahel','Unity',
              'Golden','Crystal','Zenith','Heritage','Bright'])[1 + (g % 15)] || ' ' ||
       (ARRAY['Gadgets','Stores','Mart','Traders','Concepts','Supplies','Ventures','Enterprises','Hub','Emporium'])
              [1 + ((g / 15) % 10)] || ' ' || g,
       'RC' || (100000 + g * 37),
       'sales' || g || '@vendor.seunbaba.ng',
       (ARRAY['LA','LA','LA','FC','RI','KN','OY','AN','ED','EN'])[1 + (g % 10)],
       (ARRAY[7.5, 10, 12.5, 15])[1 + (g % 4)],
       DATE '2023-01-15' + (g * 5),
       g % 25 <> 0
FROM generate_series(1, 150) g;

-- ---------------------------------------------------------------------
-- Products: realistic name and price band per leaf category
-- ---------------------------------------------------------------------
CREATE TEMP TABLE leaf_spec (leaf TEXT, brands TEXT[], items TEXT[], min_price NUMERIC, max_price NUMERIC, kg NUMERIC);
INSERT INTO leaf_spec VALUES
('Smartphones',        '{Tecno,Infinix,itel,Samsung,Xiaomi,Apple}', '{"Smartphone 128GB","Smartphone 256GB","Smartphone 64GB"}', 65000, 1450000, 0.4),
('Tablets',            '{Samsung,Apple,Lenovo,Huawei}',             '{"Tablet 10-inch","Tablet 8-inch","Kids Tablet"}',          55000, 1200000, 0.6),
('Phone Accessories',  '{Oraimo,Anker,Baseus,Ugreen}',              '{"Power Bank 20000mAh","Fast Charger 33W","Wireless Earbuds","USB-C Cable","Phone Case"}', 2500, 45000, 0.2),
('Laptops',            '{HP,Dell,Lenovo,Asus,Apple,Acer}',          '{"Laptop Core i5 8GB","Laptop Core i7 16GB","Laptop Ryzen 5","Chromebook"}', 250000, 2800000, 2.1),
('Computer Accessories','{Logitech,HP,Redragon,Ugreen}',            '{"Wireless Mouse","Keyboard","Webcam 1080p","Laptop Bag","USB Hub"}', 3500, 85000, 0.5),
('Storage Devices',    '{SanDisk,Kingston,Seagate,WD}',             '{"Flash Drive 64GB","External HDD 1TB","SSD 512GB","Memory Card 128GB"}', 4500, 160000, 0.2),
('Televisions',        '{Hisense,LG,Samsung,TCL,Polystar}',         '{"Smart TV 43-inch","Smart TV 55-inch","LED TV 32-inch"}', 120000, 1300000, 12),
('Audio',              '{JBL,Sony,Oraimo,LG}',                      '{"Bluetooth Speaker","Soundbar","Headphones","Home Theatre"}', 9000, 650000, 2.5),
('Power & Solar',      '{Felicity,Luminous,Sumec,Firman}',          '{"Inverter 3.5kVA","Solar Panel 300W","Generator 2.5kVA","Stabiliser 5kVA"}', 45000, 1600000, 25),
('Men''s Clothing',    '{Mazelle,Ankara Hub,Polo,Defacto}',          '{"Senator Kaftan","Polo Shirt","Agbada Set","Chinos Trousers"}', 6500, 120000, 0.7),
('Women''s Clothing',  '{Ankara Hub,Zara,Mazelle,Lagos Chic}',       '{"Ankara Gown","Bubu Kaftan","Jumpsuit","Two-piece Set"}', 7000, 150000, 0.6),
('Footwear',           '{Nike,Adidas,Aba Made,Clarks}',              '{"Sneakers","Leather Sandals","Corporate Shoes","Slippers"}', 5000, 180000, 1.1),
('Small Appliances',   '{Binatone,Nexus,Scanfrost,Kenwood,Philips}', '{"Blender 1.5L","Electric Kettle","Air Fryer","Microwave 20L","Pressing Iron"}', 9500, 220000, 3.0),
('Cookware',           '{Tower,Kitchen Pro,Royalford}',              '{"Non-stick Pot Set","Pressure Pot","Frying Pan","Cutlery Set"}', 4500, 90000, 2.5),
('Furniture',          '{Lagos Woodworks,HomeComfort,Ikea}',         '{"Office Chair","Study Desk","3-Seater Sofa","Wardrobe"}', 35000, 900000, 30),
('Skin Care',          '{Nivea,Cerave,Arami,The Ordinary}',          '{"Body Lotion","Shea Butter 500g","Face Serum","Sunscreen SPF50"}', 1800, 38000, 0.4),
('Hair Care',          '{Dark & Lovely,ORS,Cantu,Shea Moisture}',    '{"Hair Relaxer","Leave-in Conditioner","Braiding Hair","Hair Oil"}', 1500, 30000, 0.4),
('Fragrances',         '{Armaf,Lattafa,Hugo Boss,Dior}',             '{"Eau de Parfum 100ml","Body Mist","Oud Perfume Oil"}', 6000, 250000, 0.3),
('Beverages',          '{Milo,Peak,Lipton,Nescafe,Hollandia}',       '{"Chocolate Drink 900g","Evaporated Milk x24","Tea Bags x100","Instant Coffee 200g"}', 1800, 42000, 1.2),
('Food Cupboard',      '{Golden Penny,Dangote,Mama Gold,Power Oil}', '{"Rice 25kg","Semovita 5kg","Spaghetti x20","Vegetable Oil 5L","Garri 10kg"}', 2500, 85000, 10),
('Diapering',          '{Pampers,Huggies,Molfix}',                   '{"Diapers Size 3 x60","Diapers Size 4 x52","Baby Wipes x3"}', 3500, 32000, 2.0),
('Baby Feeding',       '{Philips Avent,Tommee Tippee,NAN,SMA}',      '{"Feeding Bottle Set","Infant Formula 800g","Sterilizer"}', 4500, 95000, 1.0);

CREATE TEMP TABLE leaf AS
SELECT row_number() OVER (ORDER BY c.category_id) AS rn, c.category_id, s.*
FROM category c JOIN leaf_spec s ON s.leaf = c.category_name
WHERE c.parent_category_id IS NOT NULL;

INSERT INTO product (vendor_id, category_id, sku, product_name, description, unit_price, weight_kg, is_active, created_at)
SELECT 1 + floor(random() * 150)::int,
       l.category_id,
       'SBB-' || lpad(g::text, 6, '0'),
       b.brand || ' ' || i.item || ' ' || (ARRAY['Classic','Pro','Lite','Max','Plus','Edition 2025','Original'])[1 + (g % 7)],
       'Genuine ' || b.brand || ' ' || i.item || ' sold on SeunBaba with nationwide delivery.',
       round((l.min_price + power(random(), 4) * (l.max_price - l.min_price)) / 50) * 50,
       round((l.kg * (0.6 + random() * 0.8))::numeric, 3),
       random() > 0.04,
       TIMESTAMPTZ '2023-06-01 00:00+01' + random() * INTERVAL '1000 days'
FROM generate_series(1, 8000) g
JOIN leaf l ON l.rn = 1 + (g % (SELECT count(*) FROM leaf))
-- "+ g * 0" correlates each lateral sub-select with the generated row; without it the
-- planner evaluates random() once per category and every product in a category gets
-- the same brand and item (bug found in Portfolio 4, see README section 7).
CROSS JOIN LATERAL (SELECT l.brands[1 + floor(random() * array_length(l.brands, 1))::int + g * 0] AS brand OFFSET 0) b
CROSS JOIN LATERAL (SELECT l.items [1 + floor(random() * array_length(l.items, 1))::int + g * 0]  AS item  OFFSET 0) i;

-- Every product is stocked in Lagos; ~40 % also in each regional hub.
INSERT INTO inventory (product_id, warehouse_id, qty_on_hand, qty_reserved, reorder_level)
SELECT p.product_id, w.warehouse_id, 20 + floor(random() * 480)::int, 0, 15
FROM product p CROSS JOIN warehouse w
WHERE w.warehouse_id = 1 OR random() + p.product_id * 0 < 0.40;   -- correlate so random() is evaluated per row

INSERT INTO inventory_movement (product_id, warehouse_id, qty_change, reason, created_at)
SELECT product_id, warehouse_id, qty_on_hand, 'RESTOCK', TIMESTAMPTZ '2023-12-31 08:00+01'
FROM inventory;

-- ---------------------------------------------------------------------
-- Coupons
-- ---------------------------------------------------------------------
INSERT INTO coupon (coupon_code, discount_pct, max_redemptions, times_redeemed, valid_from, valid_to)
SELECT code, pct, 100000, 0, vf, vf + INTERVAL '60 days'
FROM (VALUES ('DETTY-DEC24', 10, TIMESTAMPTZ '2024-12-01 00:00+01'), ('VAL-LOVE25', 7.5, '2025-02-01 00:00+01'),
             ('BLACKFRI24', 15, '2024-11-01 00:00+01'),  ('SALLAH25', 8, '2025-03-20 00:00+01'),
             ('EASTER25', 5, '2025-04-10 00:00+01'),     ('MIDYEAR25', 12, '2025-06-15 00:00+01'),
             ('INDEP-65', 6.5, '2025-09-25 00:00+01'),   ('BLACKFRI25', 20, '2025-11-01 00:00+01'),
             ('DETTY-DEC25', 10, '2025-12-01 00:00+01'), ('NEWYEAR26', 8, '2026-01-01 00:00+01'),
             ('BACK2SCH26', 9, '2026-08-20 00:00+01'),   ('INDEP-66', 6.6, '2026-09-25 00:00+01'))
     AS v(code, pct, vf);

-- ---------------------------------------------------------------------
-- Orders (2024-01-01 .. 2026-10-31, growing over time, heavy buyers skewed)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE o_stage AS
SELECT g AS seq,
       1 + floor(50000 * power(random(), 1.6))::bigint AS customer_id,
       TIMESTAMPTZ '2024-01-01 00:00+01' + power(random(), 0.75) * INTERVAL '1035 days'
           + floor(random() * 16) * INTERVAL '1 hour' AS order_date,
       random() AS r_status,
       random() AS r_coupon
FROM generate_series(1, 300000) g;

INSERT INTO customer_order (customer_id, shipping_address_id, coupon_code, order_status, order_date, delivery_fee)
SELECT s.customer_id, a.address_id,
       CASE WHEN s.r_coupon < 0.08 THEN
            (SELECT cp.coupon_code FROM coupon cp
             WHERE s.order_date BETWEEN cp.valid_from AND cp.valid_to LIMIT 1) END,
       CASE WHEN s.order_date > TIMESTAMPTZ '2026-10-24 00:00+01' THEN
                 CASE WHEN s.r_status < 0.20 THEN 'PENDING' WHEN s.r_status < 0.45 THEN 'PAID'
                      WHEN s.r_status < 0.80 THEN 'SHIPPED' WHEN s.r_status < 0.97 THEN 'DELIVERED'
                      ELSE 'CANCELLED' END
            ELSE CASE WHEN s.r_status < 0.89 THEN 'DELIVERED' WHEN s.r_status < 0.95 THEN 'CANCELLED'
                      ELSE 'REFUNDED' END
       END,
       s.order_date,
       CASE a.state_code WHEN 'LA' THEN 1500 WHEN 'OG' THEN 2000 WHEN 'FC' THEN 2500 WHEN 'RI' THEN 2500
                         ELSE 3500 END
FROM o_stage s
JOIN customer_address a ON a.customer_id = s.customer_id AND a.is_default
ORDER BY s.order_date;          -- order_id ascends with time, as in a real OLTP system

-- Order lines: 1-4 distinct products, popular products chosen more often.
CREATE TEMP TABLE line_stage AS
SELECT DISTINCT ON (o.order_id, p.product_id)
       o.order_id, p.product_id, 1 + floor(power(random(), 3) * 3)::int AS quantity
FROM customer_order o
CROSS JOIN LATERAL generate_series(1, 1 + floor(power(random(), 1.5) * 4)::int + (o.order_id * 0)::int) k
CROSS JOIN LATERAL (SELECT 1 + floor(8000 * power(random(), 2.2))::bigint + (k * 0) AS product_id OFFSET 0) p;

INSERT INTO order_item (order_id, line_no, product_id, warehouse_id, quantity, unit_price)
SELECT ls.order_id,
       row_number() OVER (PARTITION BY ls.order_id ORDER BY ls.product_id),
       ls.product_id, 1, ls.quantity,
       round(pr.unit_price * (0.88 + random() * 0.12) / 50) * 50
FROM line_stage ls JOIN product pr ON pr.product_id = ls.product_id;

-- Fulfil from the regional hub nearest the customer when the item is stocked there.
UPDATE order_item oi
SET warehouse_id = w.warehouse_id
FROM customer_order o
JOIN customer_address a ON a.address_id = o.shipping_address_id
JOIN state_region sr    ON sr.state_code = a.state_code
JOIN warehouse w        ON w.warehouse_id = CASE
        WHEN sr.geo_zone IN ('North Central')            THEN 2
        WHEN sr.geo_zone IN ('South South','South East') THEN 3
        WHEN sr.geo_zone IN ('North West','North East')  THEN 4
        ELSE 1 END
WHERE oi.order_id = o.order_id
  AND w.warehouse_id <> 1
  AND EXISTS (SELECT 1 FROM inventory i WHERE i.product_id = oi.product_id AND i.warehouse_id = w.warehouse_id);

-- Header totals (controlled redundancy - see README section 6)
UPDATE customer_order o
SET subtotal = t.sub,
    discount_amount = CASE WHEN o.coupon_code IS NULL THEN 0
                           ELSE round(t.sub * (SELECT cp.discount_pct FROM coupon cp
                                               WHERE cp.coupon_code = o.coupon_code) / 100, 2) END
FROM (SELECT order_id, sum(quantity * unit_price) AS sub FROM order_item GROUP BY order_id) t
WHERE o.order_id = t.order_id;

UPDATE coupon c SET times_redeemed = u.n
FROM (SELECT coupon_code, count(*) AS n FROM customer_order WHERE coupon_code IS NOT NULL GROUP BY 1) u
WHERE u.coupon_code = c.coupon_code;

-- Make sign-up / listing dates consistent with the first purchase.
UPDATE customer c SET created_at = f.first_order - INTERVAL '1 day'
FROM (SELECT customer_id, min(order_date) AS first_order FROM customer_order GROUP BY 1) f
WHERE f.customer_id = c.customer_id AND c.created_at >= f.first_order;

UPDATE product p SET created_at = f.first_sale - INTERVAL '1 day'
FROM (SELECT oi.product_id, min(o.order_date) AS first_sale
      FROM order_item oi JOIN customer_order o ON o.order_id = oi.order_id GROUP BY 1) f
WHERE f.product_id = p.product_id AND p.created_at >= f.first_sale;

-- ---------------------------------------------------------------------
-- Payments: failed first attempts for ~4 % of orders, then the real one
-- ---------------------------------------------------------------------
INSERT INTO payment (order_id, payment_method, amount, payment_status, gateway_ref, initiated_at, settled_at)
SELECT o.order_id, 'CARD', o.total_amount, 'FAILED',
       'PSK-F-' || o.order_id, o.order_date + INTERVAL '2 minutes', NULL
FROM customer_order o
WHERE o.order_id % 25 = 0 AND o.order_status <> 'PENDING';

INSERT INTO payment (order_id, payment_method, amount, payment_status, gateway_ref, initiated_at, settled_at)
SELECT o.order_id,
       m.method,
       o.total_amount,
       CASE o.order_status WHEN 'REFUNDED' THEN 'REFUNDED' WHEN 'CANCELLED' THEN 'FAILED' ELSE 'SUCCESSFUL' END,
       'PSK-' || to_char(o.order_date, 'YYMMDD') || '-' || o.order_id,
       o.order_date + INTERVAL '5 minutes',
       CASE WHEN o.order_status IN ('CANCELLED') THEN NULL
            ELSE o.order_date + INTERVAL '5 minutes' + random() * INTERVAL '3 minutes' END
FROM customer_order o
CROSS JOIN LATERAL (SELECT (ARRAY['CARD','CARD','CARD','BANK_TRANSFER','BANK_TRANSFER','USSD','WALLET','PAY_ON_DELIVERY'])
                           [1 + floor(random() * 8)::int + (o.order_id * 0)::int] AS method OFFSET 0) m
WHERE o.order_status <> 'PENDING';

-- ---------------------------------------------------------------------
-- Shipments and tracking events
-- ---------------------------------------------------------------------
INSERT INTO shipment (order_id, warehouse_id, courier_name, tracking_number, shipment_status, shipped_at, delivered_at)
SELECT o.order_id,
       (SELECT min(warehouse_id) FROM order_item oi WHERE oi.order_id = o.order_id),
       (ARRAY['GIG Logistics','DHL Nigeria','Kwik Delivery','Sendbox','SeunBaba Express'])[1 + (o.order_id % 5)::int],
       'OJX' || lpad(o.order_id::text, 9, '0'),
       CASE o.order_status WHEN 'SHIPPED' THEN 'IN_TRANSIT' WHEN 'REFUNDED' THEN 'RETURNED' ELSE 'DELIVERED' END,
       o.order_date + INTERVAL '1 day' + random() * INTERVAL '10 hours',
       NULL
FROM customer_order o
WHERE o.order_status IN ('SHIPPED','DELIVERED','REFUNDED');

UPDATE shipment s
SET delivered_at = s.shipped_at + (CASE WHEN a.state_code = 'LA' THEN 1 ELSE 2 END + random() * 4) * INTERVAL '1 day'
FROM customer_order o JOIN customer_address a ON a.address_id = o.shipping_address_id
WHERE o.order_id = s.order_id AND s.shipment_status IN ('DELIVERED','RETURNED');

INSERT INTO shipment_event (shipment_id, event_status, event_location, event_time)
SELECT s.shipment_id, e.status, e.loc, e.t
FROM shipment s
JOIN warehouse w ON w.warehouse_id = s.warehouse_id
JOIN customer_order o ON o.order_id = s.order_id
JOIN customer_address a ON a.address_id = o.shipping_address_id
CROSS JOIN LATERAL (VALUES
   (1, 'PACKED',           w.city, s.shipped_at - INTERVAL '3 hours'),
   (2, 'IN_TRANSIT',       w.city, s.shipped_at),
   (3, 'OUT_FOR_DELIVERY', a.city, coalesce(s.delivered_at - INTERVAL '5 hours', NULL)),
   (4, 'DELIVERED',        a.city, s.delivered_at)) AS e(step, status, loc, t)
WHERE e.t IS NOT NULL;

-- ---------------------------------------------------------------------
-- Reviews (only for delivered purchases, one per customer per product)
-- ---------------------------------------------------------------------
INSERT INTO product_review (product_id, customer_id, rating, review_text, created_at)
SELECT DISTINCT ON (oi.product_id, o.customer_id)
       oi.product_id, o.customer_id,
       (ARRAY[1,2,3,3,4,4,4,5,5,5,5])[1 + floor(random() * 11)::int],
       (ARRAY['Arrived on time, works well.','Original product, I am satisfied.',
              'Packaging was poor but item is fine.','Delivery took longer than promised.',
              'Value for money.','Not as described, returned it.','Excellent quality, will buy again.'])
              [1 + floor(random() * 7)::int],
       o.order_date + INTERVAL '7 days'
FROM order_item oi JOIN customer_order o ON o.order_id = oi.order_id
WHERE o.order_status = 'DELIVERED' AND random() < 0.10;

-- Stock movements for sales (audit trail)
INSERT INTO inventory_movement (product_id, warehouse_id, qty_change, reason, order_id, created_at)
SELECT oi.product_id, oi.warehouse_id, -oi.quantity, 'SALE', oi.order_id, o.order_date
FROM order_item oi JOIN customer_order o ON o.order_id = oi.order_id
WHERE o.order_status IN ('PAID','SHIPPED','DELIVERED');

-- The bulk UPDATEs above leave dead tuples; rewrite tables and refresh optimiser statistics.
VACUUM (FULL, ANALYZE);
