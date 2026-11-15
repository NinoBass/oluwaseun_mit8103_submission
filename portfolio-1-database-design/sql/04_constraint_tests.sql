-- =====================================================================
-- Portfolio 1 - 04_constraint_tests.sql
-- Each statement below is EXPECTED TO FAIL. It proves that a business
-- rule is enforced by the database itself rather than by application code.
-- Run with:  psql -d ojahub -e -f 04_constraint_tests.sql   (no ON_ERROR_STOP)
-- =====================================================================
SET search_path = ojahub, public;
\echo '==== Row counts after seeding ===='
SELECT 'customer' AS table_name, count(*) FROM customer UNION ALL
SELECT 'customer_address', count(*) FROM customer_address UNION ALL
SELECT 'vendor', count(*) FROM vendor UNION ALL
SELECT 'product', count(*) FROM product UNION ALL
SELECT 'inventory', count(*) FROM inventory UNION ALL
SELECT 'customer_order', count(*) FROM customer_order UNION ALL
SELECT 'order_item', count(*) FROM order_item UNION ALL
SELECT 'payment', count(*) FROM payment UNION ALL
SELECT 'shipment', count(*) FROM shipment UNION ALL
SELECT 'shipment_event', count(*) FROM shipment_event UNION ALL
SELECT 'product_review', count(*) FROM product_review UNION ALL
SELECT 'inventory_movement', count(*) FROM inventory_movement;

\echo '==== T1 Entity integrity: duplicate e-mail differing only by case (unique index on lower(email)) ===='
INSERT INTO customer (email, phone, first_name, last_name)
SELECT upper(email), '+2348000000001', 'Dup', 'Email' FROM customer WHERE customer_id = 1;

\echo '==== T2 Domain: phone number must be in +234 format ===='
INSERT INTO customer (email, phone, first_name, last_name)
VALUES ('test.user@gmail.com', '08031234567', 'Test', 'User');

\echo '==== T3 Domain: product price must be positive ===='
UPDATE product SET unit_price = -500 WHERE product_id = 10;

\echo '==== T4 Referential integrity: order line for a product that does not exist ===='
INSERT INTO order_item (order_id, line_no, product_id, warehouse_id, quantity, unit_price)
VALUES (1, 99, 999999, 1, 1, 1000);

\echo '==== T5 Referential integrity: cannot delete a customer who has orders (ON DELETE RESTRICT) ===='
DELETE FROM customer WHERE customer_id = (SELECT customer_id FROM customer_order LIMIT 1);

\echo '==== T6 Tuple constraint: reserved stock can never exceed stock on hand ===='
UPDATE inventory SET qty_reserved = qty_on_hand + 1 WHERE product_id = 1 AND warehouse_id = 1;

\echo '==== T7 Partial unique index: a customer can only have ONE default address ===='
INSERT INTO customer_address (customer_id, label, street_line, city, state_code, is_default)
VALUES (1, 'OTHER', '2 Broad Street', 'Lagos Island', 'LA', true);

\echo '==== T8 Trigger rule: order must ship to an address owned by the same customer ===='
INSERT INTO customer_order (customer_id, shipping_address_id)
VALUES (1, (SELECT address_id FROM customer_address WHERE customer_id = 2 AND is_default));

\echo '==== T9 Generated column cannot be written directly ===='
UPDATE customer_order SET total_amount = 0 WHERE order_id = 1;

\echo '==== T10 Coupon cannot be redeemed beyond its limit ===='
UPDATE coupon SET times_redeemed = max_redemptions + 1 WHERE coupon_code = 'BLACKFRI25';

\echo '==== T11 Composite PK: duplicate (order_id, line_no) ===='
INSERT INTO order_item (order_id, line_no, product_id, warehouse_id, quantity, unit_price)
SELECT order_id, line_no, product_id, warehouse_id, quantity, unit_price FROM order_item WHERE order_id = 1 AND line_no = 1;

\echo '==== T12 Valid statement for contrast: generated total recalculates automatically ===='
BEGIN;
UPDATE customer_order SET delivery_fee = delivery_fee + 500 WHERE order_id = 1
RETURNING order_id, subtotal, discount_amount, delivery_fee, total_amount;
ROLLBACK;
