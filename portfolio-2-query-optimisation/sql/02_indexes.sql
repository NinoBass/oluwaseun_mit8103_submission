-- =====================================================================
-- Portfolio 2 - 02_indexes.sql
-- Optimisation indexes. Each one is justified by a specific query plan
-- (see README.md section 3). Applied AFTER the "before" benchmark.
-- =====================================================================
SET search_path = seunbaba, public;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Q1: FK index + sort order + covering columns -> index-only access path
--     for "latest orders of a customer". DESC matches ORDER BY ... DESC LIMIT.
CREATE INDEX ix_order_customer_date
    ON customer_order (customer_id, order_date DESC)
    INCLUDE (order_status, total_amount);

-- Q2: FK indexes on the tracking path (PostgreSQL does NOT index FKs automatically).
CREATE INDEX ix_shipment_order       ON shipment (order_id);
CREATE INDEX ix_shipment_event_ship  ON shipment_event (shipment_id, event_time);

-- Q3/Q4: range predicates on order_date. Orders are inserted in time order, so a
--        BRIN index (min/max per 32-page block range) is tiny compared with a B-tree.
--        Caveat measured on this data set: the bulk UPDATEs in the seed script moved
--        row versions, so pg_stats.correlation for order_date is only ~0.54 and the
--        BRIN index is "lossy" (see README section 3, Q3).
CREATE INDEX brin_order_date ON customer_order USING brin (order_date) WITH (pages_per_range = 32);

-- Q4/Q7: join from order lines to products (FK, not indexed by default)
CREATE INDEX ix_order_item_product ON order_item (product_id);
CREATE INDEX ix_product_vendor     ON product (vendor_id);

-- Q5: only ~0.3 % of orders are 'PAID' (awaiting dispatch). A partial index holds
--     just those rows, stays tiny, and is maintained only for qualifying rows.
CREATE INDEX ix_order_awaiting_dispatch
    ON customer_order (order_date)
    WHERE order_status = 'PAID';

-- Q6: leading-wildcard ILIKE cannot use a B-tree. A trigram GIN index can.
CREATE INDEX gin_product_name_trgm ON product USING gin (product_name gin_trgm_ops);

-- Plain VACUUM sets the visibility map (VACUUM FULL does not), which is what
-- allows index-only scans on the covering index; ANALYZE refreshes statistics.
VACUUM (ANALYZE) customer_order, order_item, product, shipment, shipment_event;

-- Index sizes for the report
SELECT indexrelname AS index_name, relname AS table_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'seunbaba' AND indexrelname ~ '^(ix_|brin_|gin_)'
ORDER BY pg_relation_size(indexrelid) DESC;
