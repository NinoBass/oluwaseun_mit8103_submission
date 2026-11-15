-- =====================================================================
-- Portfolio 3 - 02_commit_rollback_demo.sql
-- Single-session demonstrations of COMMIT, automatic ROLLBACK on error,
-- explicit ROLLBACK, SAVEPOINT / ROLLBACK TO SAVEPOINT, and durability.
-- Run:  psql -d seunbaba -e -f sql/02_commit_rollback_demo.sql
-- =====================================================================
SET search_path = seunbaba, public;
\set QUIET off
\pset footer off

-- Helper view for before/after snapshots
CREATE OR REPLACE TEMP VIEW flash_stock AS
SELECT p.sku, i.qty_on_hand, i.qty_reserved, i.qty_on_hand - i.qty_reserved AS available
FROM product p JOIN inventory i USING (product_id)
WHERE p.sku LIKE 'SBB-FLASH-%' ORDER BY p.sku;

\echo '########## T1  COMMIT: successful checkout of 2 phones + 1 earbuds ##########'
SELECT * FROM flash_stock;
SELECT count(*) AS orders_before FROM customer_order \gset
BEGIN;
SELECT place_order(
         1207,
         jsonb_build_array(
            jsonb_build_object('product_id', (SELECT product_id FROM product WHERE sku = 'SBB-FLASH-001'), 'qty', 2),
            jsonb_build_object('product_id', (SELECT product_id FROM product WHERE sku = 'SBB-FLASH-002'), 'qty', 1)),
         'FLASH3', 'CARD') AS new_order_id \gset
SELECT order_id, order_status, subtotal, discount_amount, delivery_fee, total_amount
FROM customer_order WHERE order_id = :new_order_id;
COMMIT;
SELECT * FROM flash_stock;                     -- 2 and 1 units now RESERVED
SELECT settle_payment(:new_order_id, true);    -- gateway says "success" (own transaction, autocommit)
SELECT * FROM flash_stock;                     -- reservation converted into a deduction
SELECT o.order_id, o.order_status, p.payment_status, p.amount, p.gateway_ref
FROM customer_order o JOIN payment p USING (order_id) WHERE o.order_id = :new_order_id;

\echo '########## T2  AUTOMATIC ROLLBACK: basket asks for more phones than exist ##########'
-- line 1 (earbuds) succeeds inside the function, line 2 (30 phones) fails:
-- the error aborts the WHOLE transaction - no order, no reservation of earbuds.
SELECT count(*) AS orders_before FROM customer_order;
BEGIN;
SELECT place_order(
         1207,
         jsonb_build_array(
            jsonb_build_object('product_id', (SELECT product_id FROM product WHERE sku = 'SBB-FLASH-002'), 'qty', 1),
            jsonb_build_object('product_id', (SELECT product_id FROM product WHERE sku = 'SBB-FLASH-001'), 'qty', 30)));
SELECT 'this statement is refused because the transaction is aborted';
COMMIT;                                        -- PostgreSQL turns this COMMIT into ROLLBACK
SELECT count(*) AS orders_after FROM customer_order;
SELECT * FROM flash_stock;                     -- unchanged

\echo '########## T3  EXPLICIT ROLLBACK: agent cancels a manual stock adjustment ##########'
BEGIN;
UPDATE inventory SET qty_on_hand = qty_on_hand + 100
WHERE product_id = (SELECT product_id FROM product WHERE sku = 'SBB-FLASH-001') AND warehouse_id = 1;
SELECT * FROM flash_stock;                     -- visible INSIDE the transaction
ROLLBACK;
SELECT * FROM flash_stock;                     -- gone

\echo '########## T4  SAVEPOINT: coupon fails, checkout continues without it ##########'
BEGIN;
SAVEPOINT try_with_coupon;
SELECT place_order(50,
         jsonb_build_array(jsonb_build_object('product_id', (SELECT product_id FROM product WHERE sku = 'SBB-FLASH-002'), 'qty', 1)),
         'BLACKFRI24');                        -- expired coupon -> error
ROLLBACK TO SAVEPOINT try_with_coupon;         -- undo only the failed attempt
SELECT place_order(50,
         jsonb_build_array(jsonb_build_object('product_id', (SELECT product_id FROM product WHERE sku = 'SBB-FLASH-002'), 'qty', 1)),
         NULL) AS saved_order_id \gset
COMMIT;
SELECT order_id, coupon_code, order_status, total_amount FROM customer_order WHERE order_id = :saved_order_id;
SELECT * FROM flash_stock;

\echo '########## T5  Coupon limit (3 redemptions) enforced transactionally ##########'
SELECT coupon_code, max_redemptions, times_redeemed FROM coupon WHERE coupon_code = 'FLASH3';

\echo '########## T6  DURABILITY: commit is flushed to WAL before success is returned ##########'
SHOW synchronous_commit;
SHOW fsync;
SELECT pg_current_wal_lsn() AS wal_position_after_commits;
