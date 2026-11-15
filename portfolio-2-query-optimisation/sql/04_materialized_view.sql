-- =====================================================================
-- Portfolio 2 - 04_materialized_view.sql
-- Q4 cannot be fixed with an index: order_item has no date, so every
-- reporting run must scan all 640k lines and join them to orders.
-- Solution: pre-aggregate sales per product per day ONCE (nightly
-- REFRESH ... CONCURRENTLY), then answer reports from ~400k small rows
-- that are already filtered, joined and summed.
-- =====================================================================
SET search_path = ojahub, public;

DROP MATERIALIZED VIEW IF EXISTS mv_daily_product_sales;
CREATE MATERIALIZED VIEW mv_daily_product_sales AS
SELECT (o.order_date AT TIME ZONE 'Africa/Lagos')::date AS sale_date,
       oi.product_id,
       sum(oi.quantity)                 AS units,
       sum(oi.quantity * oi.unit_price) AS revenue
FROM customer_order o
JOIN order_item oi ON oi.order_id = o.order_id
WHERE o.order_status <> 'CANCELLED'
GROUP BY 1, 2;

-- Unique index is required for REFRESH MATERIALIZED VIEW CONCURRENTLY
-- (refresh without blocking readers); sale_date leads for range scans.
CREATE UNIQUE INDEX ux_mv_dps ON mv_daily_product_sales (sale_date, product_id);
ANALYZE mv_daily_product_sales;

-- Nightly job (e.g. pg_cron at 01:00 WAT):
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_product_sales;

SELECT count(*) AS mv_rows, pg_size_pretty(pg_total_relation_size('mv_daily_product_sales')) AS mv_size
FROM mv_daily_product_sales;

-- @Q4b  same business question as Q4, answered from the summary.
--        Aggregate by product_id FIRST (early / eager aggregation), then join
--        the ~8k aggregated rows to the dimension tables instead of ~62k raw rows.
WITH agg AS (
    SELECT product_id, sum(units) AS units, sum(revenue) AS revenue
    FROM mv_daily_product_sales
    WHERE sale_date >= DATE '2026-08-02'
    GROUP BY product_id
), sales AS (
    SELECT p.product_id, p.product_name, parent.category_name AS top_category, a.units, a.revenue
    FROM agg a
    JOIN product p        ON p.product_id = a.product_id
    JOIN category leaf    ON leaf.category_id = p.category_id
    JOIN category parent  ON parent.category_id = leaf.parent_category_id
)
SELECT top_category, rnk, product_name, units, revenue
FROM (SELECT s.*, dense_rank() OVER (PARTITION BY top_category ORDER BY revenue DESC) AS rnk FROM sales s) r
WHERE rnk <= 5
ORDER BY top_category, rnk;
