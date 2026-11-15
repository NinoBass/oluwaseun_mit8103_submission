-- =====================================================================
-- Portfolio 3 - Odunlade_Oluwaseun_301931438_00_demo_setup.sql  (idempotent: re-run before every demo)
-- A "flash sale" product with exactly 25 units in Lagos, and a coupon
-- that may be redeemed only 3 times. These small numbers make race
-- conditions visible.
-- =====================================================================
SET search_path = seunbaba, public;

-- Queue tickets for a flash sale. Business rule (enforced by application code,
-- NOT by a constraint): at most 2 tickets per customer per product. Used for the
-- write-skew demonstration (D3).
CREATE TABLE IF NOT EXISTS flash_sale_ticket (
    ticket_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  BIGINT NOT NULL REFERENCES customer (customer_id),
    product_id   BIGINT NOT NULL REFERENCES product (product_id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_ticket_customer_product ON flash_sale_ticket (customer_id, product_id);

-- Remove anything a previous demo run created (orders, payments, stock movements, tickets)
DELETE FROM flash_sale_ticket;
DELETE FROM inventory_movement WHERE product_id IN (SELECT product_id FROM product WHERE sku LIKE 'SBB-FLASH-%');
DELETE FROM payment  WHERE order_id IN (SELECT order_id FROM order_item oi JOIN product p USING (product_id) WHERE p.sku LIKE 'SBB-FLASH-%');
DELETE FROM customer_order WHERE order_id IN (SELECT order_id FROM order_item oi JOIN product p USING (product_id) WHERE p.sku LIKE 'SBB-FLASH-%');

-- Flash-sale products (created once, ids stay stable across resets)
INSERT INTO product (vendor_id, category_id, sku, product_name, unit_price, weight_kg)
SELECT 1, category_id, 'SBB-FLASH-001', 'Infinix Hot 50 128GB (Flash Sale)', 99000, 0.4
FROM category WHERE category_name = 'Smartphones'
ON CONFLICT (sku) DO NOTHING;
INSERT INTO product (vendor_id, category_id, sku, product_name, unit_price, weight_kg)
SELECT 1, category_id, 'SBB-FLASH-002', 'Oraimo FreePods 4 (Flash Sale)', 19500, 0.1
FROM category WHERE category_name = 'Phone Accessories'
ON CONFLICT (sku) DO NOTHING;

-- Exactly 25 units of each, nothing reserved
INSERT INTO inventory (product_id, warehouse_id, qty_on_hand, qty_reserved)
SELECT product_id, 1, 25, 0 FROM product WHERE sku LIKE 'SBB-FLASH-%'
ON CONFLICT (product_id, warehouse_id) DO UPDATE SET qty_on_hand = 25, qty_reserved = 0;

-- Coupon limited to 3 redemptions, valid for the next 7 days
INSERT INTO coupon (coupon_code, discount_pct, max_redemptions, times_redeemed, valid_from, valid_to)
VALUES ('FLASH3', 50, 3, 0, now() - INTERVAL '1 hour', now() + INTERVAL '7 days')
ON CONFLICT (coupon_code) DO UPDATE
   SET times_redeemed = 0, valid_from = EXCLUDED.valid_from, valid_to = EXCLUDED.valid_to;

SELECT p.product_id, p.sku, p.product_name, i.warehouse_id, i.qty_on_hand, i.qty_reserved
FROM product p JOIN inventory i USING (product_id) WHERE p.sku LIKE 'SBB-FLASH-%' ORDER BY 1;
