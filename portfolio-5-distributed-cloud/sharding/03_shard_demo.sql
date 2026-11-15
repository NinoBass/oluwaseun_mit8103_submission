-- =====================================================================
-- Portfolio 5 - sharding/03_shard_demo.sql   (run on coordinator with psql -e)
-- =====================================================================
SET enable_partitionwise_aggregate = on;   -- push GROUP BY down to each shard
SET enable_partitionwise_join = on;        -- push co-located joins down to each shard
\pset footer off

\echo '==== S1 Data distribution: hash(customer_id) MODULUS 2 ===='
SELECT tableoid::regclass AS shard_partition, count(*) AS orders, count(DISTINCT customer_id) AS customers,
       sum(total_amount) AS revenue
FROM dist.customer_order GROUP BY 1 ORDER BY 1;

\echo '==== S2 Single-customer query: partition pruning sends it to ONE shard ===='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT order_id, order_date, order_status, total_amount
FROM dist.customer_order WHERE customer_id = 1207 ORDER BY order_date DESC LIMIT 5;
SELECT order_id, order_date, order_status, total_amount, tableoid::regclass AS served_by
FROM dist.customer_order WHERE customer_id = 1207 ORDER BY order_date DESC LIMIT 5;

\echo '==== S3 Co-located data: orders and lines of one customer come from the SAME single shard ===='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT o.order_id, o.order_date, count(*) AS lines, sum(i.quantity * i.unit_price) AS goods_value
FROM dist.customer_order o JOIN dist.order_item i ON i.customer_id = o.customer_id AND i.order_id = o.order_id
WHERE o.customer_id = 1207 GROUP BY o.order_id, o.order_date;

\echo '==== S4 Global report by geo_zone (not the shard key): shards filter, coordinator aggregates ===='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT geo_zone, count(*) AS orders, sum(total_amount) AS revenue
FROM dist.customer_order WHERE order_status IN ('PAID','SHIPPED','DELIVERED') GROUP BY geo_zone;
SELECT geo_zone, count(*) AS orders, sum(total_amount) AS revenue
FROM dist.customer_order WHERE order_status IN ('PAID','SHIPPED','DELIVERED') GROUP BY geo_zone ORDER BY 1;

\echo '==== S4b Report grouped BY THE SHARD KEY: whole GROUP BY pushed to both shards, run asynchronously ===='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT customer_id, count(*) AS orders, sum(total_amount) AS spend
FROM dist.customer_order GROUP BY customer_id ORDER BY spend DESC LIMIT 5;
SELECT customer_id, count(*) AS orders, sum(total_amount) AS spend
FROM dist.customer_order GROUP BY customer_id ORDER BY spend DESC LIMIT 5;

\echo '==== S5 Correctness: sharded result vs single-node result (rows in one but not the other) ===='
WITH sharded AS (
    SELECT geo_zone, count(*) n, sum(total_amount) rev FROM dist.customer_order
    WHERE order_status IN ('PAID','SHIPPED','DELIVERED') GROUP BY 1),
single AS (
    SELECT sr.geo_zone, count(*) n, sum(o.total_amount) rev
    FROM seunbaba.customer_order o JOIN seunbaba.customer_address a ON a.address_id = o.shipping_address_id
    JOIN seunbaba.state_region sr ON sr.state_code = a.state_code
    WHERE o.order_date >= '2026-01-01 00:00+01' AND o.order_date < '2026-11-01 00:00+01'
      AND o.order_status IN ('PAID','SHIPPED','DELIVERED') GROUP BY 1)
SELECT 'only in sharded' AS side, * FROM (TABLE sharded EXCEPT TABLE single) a
UNION ALL
SELECT 'only in single-node', * FROM (TABLE single EXCEPT TABLE sharded) b;

\echo '==== S6 Write routing: the coordinator sends each new order to the right shard ===='
BEGIN;
INSERT INTO dist.customer_order VALUES
  (900001, 1207, now(), 'PENDING', 'LA', 'South West', 25000),
  (900002, 50,   now(), 'PENDING', 'FC', 'North Central', 18000);
SELECT order_id, customer_id, tableoid::regclass AS stored_on FROM dist.customer_order WHERE order_id IN (900001, 900002);
ROLLBACK;   -- distributed rollback: postgres_fdw rolls back the remote transactions as well
SELECT count(*) AS left_after_rollback FROM dist.customer_order WHERE order_id IN (900001, 900002);
