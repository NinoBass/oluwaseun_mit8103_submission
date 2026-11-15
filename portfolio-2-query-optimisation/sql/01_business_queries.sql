-- =====================================================================
-- Portfolio 2 - 01_business_queries.sql
-- Six realistic OjaHub workloads. Each is run with
--   EXPLAIN (ANALYZE, BUFFERS)  before and after optimisation
-- by run_benchmark.sh. The plain query text lives here.
-- =====================================================================
SET search_path = ojahub, public;

-- Q1  Customer-service lookup: "show me this customer's last 10 orders"
--     (login is by e-mail, typed in any letter case)
-- @Q1
SELECT o.order_id, o.order_date, o.order_status, o.total_amount
FROM customer c
JOIN customer_order o ON o.customer_id = c.customer_id
WHERE lower(c.email) = lower('Chinedu.Ibrahim1207@Outlook.com')
ORDER BY o.order_date DESC
LIMIT 10;

-- Q2  Order tracking page: shipment + full event history for one order
-- @Q2
SELECT s.tracking_number, s.courier_name, e.event_status, e.event_location, e.event_time
FROM shipment s
JOIN shipment_event e ON e.shipment_id = s.shipment_id
WHERE s.order_id = 245000
ORDER BY e.event_time;

-- Q3  Management report: monthly revenue and order count per geo-zone for 2026,
--     with month-on-month growth (window function)
-- @Q3
WITH monthly AS (
    SELECT sr.geo_zone,
           date_trunc('month', o.order_date) AS month,
           count(*)                          AS orders,
           sum(o.total_amount)               AS revenue
    FROM customer_order o
    JOIN customer_address a ON a.address_id = o.shipping_address_id
    JOIN state_region sr    ON sr.state_code = a.state_code
    WHERE o.order_date >= TIMESTAMPTZ '2026-01-01 00:00+01'
      AND o.order_date <  TIMESTAMPTZ '2026-11-01 00:00+01'
      AND o.order_status IN ('PAID','SHIPPED','DELIVERED')
    GROUP BY sr.geo_zone, date_trunc('month', o.order_date)
)
SELECT geo_zone, to_char(month, 'YYYY-MM') AS month, orders, revenue,
       round(100.0 * (revenue - lag(revenue) OVER w) / lag(revenue) OVER w, 1) AS mom_growth_pct
FROM monthly
WINDOW w AS (PARTITION BY geo_zone ORDER BY month)
ORDER BY geo_zone, month;

-- Q4  Merchandising: top 5 best-selling products in each top-level category
--     over the last 90 days (ranking window function)
-- @Q4
WITH sales AS (
    SELECT p.product_id, p.product_name, parent.category_name AS top_category,
           sum(oi.quantity)                 AS units,
           sum(oi.quantity * oi.unit_price) AS revenue
    FROM customer_order o
    JOIN order_item oi    ON oi.order_id = o.order_id
    JOIN product p        ON p.product_id = oi.product_id
    JOIN category leaf    ON leaf.category_id = p.category_id
    JOIN category parent  ON parent.category_id = leaf.parent_category_id
    WHERE o.order_date >= TIMESTAMPTZ '2026-08-02 00:00+01'
      AND o.order_status <> 'CANCELLED'
    GROUP BY p.product_id, p.product_name, parent.category_name
)
SELECT top_category, rnk, product_name, units, revenue
FROM (SELECT s.*, dense_rank() OVER (PARTITION BY top_category ORDER BY revenue DESC) AS rnk FROM sales s) r
WHERE rnk <= 5
ORDER BY top_category, rnk;

-- Q5  Operations: orders still waiting to be dispatched (status PAID) for more than
--     24 hours, oldest first - polled every minute by the warehouse dashboard
-- @Q5
SELECT o.order_id, o.order_date, c.first_name || ' ' || c.last_name AS customer, o.total_amount
FROM customer_order o
JOIN customer c ON c.customer_id = o.customer_id
WHERE o.order_status = 'PAID'
  AND o.order_date < TIMESTAMPTZ '2026-10-31 00:00+01' - INTERVAL '24 hours'
ORDER BY o.order_date
LIMIT 50;

-- Q6  Catalogue search box: products whose name contains a typed fragment
-- @Q6
SELECT product_id, sku, product_name, unit_price
FROM product
WHERE product_name ILIKE '%air fryer%'
  AND is_active
ORDER BY unit_price
LIMIT 20;

-- Q7  Vendor statement: each vendor's revenue, commission and average rating
--     for Q3 2026 (correlated sub-query version - deliberately naive)
-- @Q7
SELECT v.vendor_id, v.business_name,
       (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
          FROM order_item oi
          JOIN product p ON p.product_id = oi.product_id
          JOIN customer_order o ON o.order_id = oi.order_id
         WHERE p.vendor_id = v.vendor_id
           AND o.order_status = 'DELIVERED'
           AND o.order_date >= TIMESTAMPTZ '2026-07-01 00:00+01'
           AND o.order_date <  TIMESTAMPTZ '2026-10-01 00:00+01') AS gross_sales,
       (SELECT round(avg(r.rating), 2)
          FROM product_review r JOIN product p ON p.product_id = r.product_id
         WHERE p.vendor_id = v.vendor_id) AS avg_rating
FROM vendor v
WHERE v.is_active
ORDER BY gross_sales DESC
LIMIT 10;
