-- =====================================================================
-- Portfolio 5 - sharding/Odunlade_Oluwaseun_301931438_02_coordinator.sql
-- Run on the coordinator (the main SeunBaba server, port 5432, db seunbaba).
-- Declarative hash partitioning whose partitions are FOREIGN tables on
-- two shard servers (postgres_fdw). The application keeps talking to one
-- logical table; the coordinator routes rows and queries to the shards.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SCHEMA IF EXISTS dist CASCADE;
DROP SERVER IF EXISTS shard1 CASCADE;
DROP SERVER IF EXISTS shard2 CASCADE;
CREATE SCHEMA dist;

-- async_capable: both shards are scanned in parallel; batch_size: bulk INSERTs
CREATE SERVER shard1 FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5434', dbname 'seunbaba_shard', async_capable 'true', batch_size '1000', fetch_size '10000');
CREATE SERVER shard2 FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5435', dbname 'seunbaba_shard', async_capable 'true', batch_size '1000', fetch_size '10000');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard1 OPTIONS (user 'postgres');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard2 OPTIONS (user 'postgres');

CREATE TABLE dist.customer_order (
    order_id BIGINT NOT NULL, customer_id BIGINT NOT NULL, order_date TIMESTAMPTZ NOT NULL,
    order_status VARCHAR(12) NOT NULL, ship_state CHAR(2) NOT NULL, geo_zone VARCHAR(15) NOT NULL,
    total_amount NUMERIC(14,2) NOT NULL
) PARTITION BY HASH (customer_id);
CREATE FOREIGN TABLE dist.customer_order_shard1 PARTITION OF dist.customer_order
    FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER shard1 OPTIONS (schema_name 'public', table_name 'customer_order_s');
CREATE FOREIGN TABLE dist.customer_order_shard2 PARTITION OF dist.customer_order
    FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER shard2 OPTIONS (schema_name 'public', table_name 'customer_order_s');

CREATE TABLE dist.order_item (
    order_id BIGINT NOT NULL, customer_id BIGINT NOT NULL, line_no SMALLINT NOT NULL,
    product_id BIGINT NOT NULL, quantity INT NOT NULL, unit_price NUMERIC(12,2) NOT NULL
) PARTITION BY HASH (customer_id);
CREATE FOREIGN TABLE dist.order_item_shard1 PARTITION OF dist.order_item
    FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER shard1 OPTIONS (schema_name 'public', table_name 'order_item_s');
CREATE FOREIGN TABLE dist.order_item_shard2 PARTITION OF dist.order_item
    FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER shard2 OPTIONS (schema_name 'public', table_name 'order_item_s');

-- TRUNCATE is forwarded to the shards by postgres_fdw (makes the script re-runnable).
TRUNCATE dist.order_item, dist.customer_order;

-- Load 2026 orders from the single-node schema; rows are routed by hash(customer_id).
INSERT INTO dist.customer_order
SELECT o.order_id, o.customer_id, o.order_date, o.order_status, a.state_code, sr.geo_zone, o.total_amount
FROM seunbaba.customer_order o
JOIN seunbaba.customer_address a ON a.address_id = o.shipping_address_id
JOIN seunbaba.state_region sr ON sr.state_code = a.state_code
WHERE o.order_date >= '2026-01-01 00:00+01' AND o.order_date < '2026-11-01 00:00+01';

INSERT INTO dist.order_item
SELECT oi.order_id, o.customer_id, oi.line_no, oi.product_id, oi.quantity, oi.unit_price
FROM seunbaba.order_item oi JOIN seunbaba.customer_order o USING (order_id)
WHERE o.order_date >= '2026-01-01 00:00+01' AND o.order_date < '2026-11-01 00:00+01';

ANALYZE dist.customer_order, dist.order_item;
