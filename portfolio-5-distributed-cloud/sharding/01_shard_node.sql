-- =====================================================================
-- Portfolio 5 - sharding/01_shard_node.sql
-- Run on EVERY shard server (ports 5434 and 5435), in database seunbaba_shard.
-- Orders and their lines are sharded by customer_id, so one customer's
-- orders AND lines always live on the same shard (co-location) and the
-- "my orders" page never needs a cross-shard join.
-- =====================================================================
DROP TABLE IF EXISTS order_item_s, customer_order_s;

CREATE TABLE customer_order_s (
    order_id      BIGINT        NOT NULL,
    customer_id   BIGINT        NOT NULL,          -- shard key
    order_date    TIMESTAMPTZ   NOT NULL,
    order_status  VARCHAR(12)   NOT NULL,
    ship_state    CHAR(2)       NOT NULL,
    geo_zone      VARCHAR(15)   NOT NULL,
    total_amount  NUMERIC(14,2) NOT NULL,
    PRIMARY KEY (customer_id, order_id)            -- shard key must be part of the key
);
CREATE TABLE order_item_s (
    order_id      BIGINT        NOT NULL,
    customer_id   BIGINT        NOT NULL,          -- shard key copied down for co-location
    line_no       SMALLINT      NOT NULL,
    product_id    BIGINT        NOT NULL,
    quantity      INT           NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (customer_id, order_id, line_no),
    FOREIGN KEY (customer_id, order_id) REFERENCES customer_order_s (customer_id, order_id) ON DELETE CASCADE
);
CREATE INDEX ix_s_order_date ON customer_order_s (order_date);
