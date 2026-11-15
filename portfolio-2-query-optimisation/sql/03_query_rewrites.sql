-- =====================================================================
-- Portfolio 2 - 03_query_rewrites.sql
-- Logical (query-level) optimisation: Q7 rewritten so that each fact
-- table is aggregated ONCE (set-based) instead of once per vendor
-- (correlated sub-query executed 144 times). Same result set.
-- =====================================================================
SET search_path = seunbaba, public;

-- @Q7b
WITH sales AS (
    SELECT p.vendor_id, sum(oi.quantity * oi.unit_price) AS gross_sales
    FROM customer_order o
    JOIN order_item oi ON oi.order_id = o.order_id
    JOIN product p     ON p.product_id = oi.product_id
    WHERE o.order_status = 'DELIVERED'
      AND o.order_date >= TIMESTAMPTZ '2026-07-01 00:00+01'
      AND o.order_date <  TIMESTAMPTZ '2026-10-01 00:00+01'
    GROUP BY p.vendor_id
), ratings AS (
    SELECT p.vendor_id, round(avg(r.rating), 2) AS avg_rating
    FROM product_review r JOIN product p ON p.product_id = r.product_id
    GROUP BY p.vendor_id
)
SELECT v.vendor_id, v.business_name,
       coalesce(s.gross_sales, 0) AS gross_sales,
       r.avg_rating
FROM vendor v
LEFT JOIN sales   s ON s.vendor_id = v.vendor_id
LEFT JOIN ratings r ON r.vendor_id = v.vendor_id
WHERE v.is_active
ORDER BY gross_sales DESC
LIMIT 10;
