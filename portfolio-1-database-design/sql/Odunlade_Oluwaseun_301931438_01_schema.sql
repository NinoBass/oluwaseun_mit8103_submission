-- =====================================================================
-- MIT 8103 Advanced Database Systems - Portfolio 1
-- Case study : SeunBaba Commerce Ltd (simulated multi-vendor e-commerce
--              marketplace headquartered in Lagos, Nigeria)
-- File       : Odunlade_Oluwaseun_301931438_01_schema.sql
-- Purpose    : Physical relational schema (PostgreSQL 16) with keys,
--              domain constraints and referential integrity rules.
-- Author     : Odunlade Oluwaseun (301931438)
-- =====================================================================

DROP SCHEMA IF EXISTS seunbaba CASCADE;
CREATE SCHEMA seunbaba;
SET search_path = seunbaba, public;

-- SeunBaba trades in West Africa Time (UTC+1). Functions such as date_trunc('month', ...)
-- use the SESSION time zone, so the database default must be Lagos time; otherwise an
-- order placed at 00:30 WAT on 1 October is reported as a September sale.
DO $$ BEGIN
    EXECUTE format('ALTER DATABASE %I SET timezone = %L', current_database(), 'Africa/Lagos');
END $$;
SET timezone = 'Africa/Lagos';

-- ---------------------------------------------------------------------
-- Reference / lookup data
-- ---------------------------------------------------------------------
-- Nigerian states. Keeping state names in their own table removes the
-- transitive dependency  city -> state_name -> geo_zone  from addresses.
CREATE TABLE state_region (
    state_code   CHAR(2)      PRIMARY KEY,
    state_name   VARCHAR(40)  NOT NULL UNIQUE,
    geo_zone     VARCHAR(15)  NOT NULL
        CHECK (geo_zone IN ('North Central','North East','North West',
                            'South East','South South','South West'))
);

-- ---------------------------------------------------------------------
-- Customers and their delivery addresses
-- ---------------------------------------------------------------------
CREATE TABLE customer (
    customer_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email           VARCHAR(255) NOT NULL,
    phone           VARCHAR(20)  NOT NULL,
    first_name      VARCHAR(60)  NOT NULL,
    last_name       VARCHAR(60)  NOT NULL,
    date_of_birth   DATE,
    account_status  VARCHAR(12)  NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_customer_status CHECK (account_status IN ('ACTIVE','SUSPENDED','CLOSED')),
    CONSTRAINT ck_customer_email  CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$'),
    CONSTRAINT ck_customer_phone  CHECK (phone ~ '^\+234[0-9]{10}$'),
    CONSTRAINT ck_customer_adult  CHECK (date_of_birth IS NULL OR date_of_birth <= DATE '2010-12-31'),
    CONSTRAINT uq_customer_phone  UNIQUE (phone)
);
-- Case-insensitive uniqueness of e-mail (Ada@x.com and ada@x.com are the same login).
CREATE UNIQUE INDEX uq_customer_email_ci ON customer (lower(email));

CREATE TABLE customer_address (
    address_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  BIGINT       NOT NULL REFERENCES customer (customer_id) ON DELETE CASCADE,
    label        VARCHAR(20)  NOT NULL DEFAULT 'HOME',
    street_line  VARCHAR(200) NOT NULL,
    city         VARCHAR(80)  NOT NULL,
    state_code   CHAR(2)      NOT NULL REFERENCES state_region (state_code),
    is_default   BOOLEAN      NOT NULL DEFAULT false
);
-- Business rule: a customer can have at most ONE default address (partial unique index).
CREATE UNIQUE INDEX uq_customer_default_address ON customer_address (customer_id) WHERE is_default;

-- ---------------------------------------------------------------------
-- Vendors (sellers on the marketplace), catalogue and stock
-- ---------------------------------------------------------------------
CREATE TABLE vendor (
    vendor_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    business_name    VARCHAR(120) NOT NULL UNIQUE,
    cac_rc_number    VARCHAR(12)  NOT NULL UNIQUE,      -- Corporate Affairs Commission reg. no.
    contact_email    VARCHAR(255) NOT NULL,
    state_code       CHAR(2)      NOT NULL REFERENCES state_region (state_code),
    commission_pct   NUMERIC(4,2) NOT NULL DEFAULT 10.00 CHECK (commission_pct BETWEEN 0 AND 40),
    onboarded_on     DATE         NOT NULL DEFAULT current_date,
    is_active        BOOLEAN      NOT NULL DEFAULT true
);

-- Self-referencing hierarchy: Electronics > Phones, Fashion > Footwear ...
CREATE TABLE category (
    category_id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_name       VARCHAR(80) NOT NULL,
    parent_category_id  INT REFERENCES category (category_id) ON DELETE RESTRICT,
    CONSTRAINT uq_category_name_per_parent UNIQUE (parent_category_id, category_name),
    CONSTRAINT ck_category_not_own_parent CHECK (parent_category_id IS DISTINCT FROM category_id)
);

CREATE TABLE product (
    product_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vendor_id     INT           NOT NULL REFERENCES vendor (vendor_id) ON DELETE RESTRICT,
    category_id   INT           NOT NULL REFERENCES category (category_id) ON DELETE RESTRICT,
    sku           VARCHAR(32)   NOT NULL UNIQUE,
    product_name  VARCHAR(160)  NOT NULL,
    description   TEXT,
    unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price > 0),   -- Naira
    weight_kg     NUMERIC(7,3)  CHECK (weight_kg > 0),
    is_active     BOOLEAN       NOT NULL DEFAULT true,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE warehouse (
    warehouse_id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    warehouse_name  VARCHAR(60) NOT NULL UNIQUE,
    city            VARCHAR(80) NOT NULL,
    state_code      CHAR(2)     NOT NULL REFERENCES state_region (state_code)
);

-- Stock per product per warehouse (composite primary key).
CREATE TABLE inventory (
    product_id     BIGINT      NOT NULL REFERENCES product (product_id) ON DELETE CASCADE,
    warehouse_id   SMALLINT    NOT NULL REFERENCES warehouse (warehouse_id) ON DELETE RESTRICT,
    qty_on_hand    INT         NOT NULL DEFAULT 0 CHECK (qty_on_hand  >= 0),
    qty_reserved   INT         NOT NULL DEFAULT 0 CHECK (qty_reserved >= 0),
    reorder_level  INT         NOT NULL DEFAULT 10 CHECK (reorder_level >= 0),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, warehouse_id),
    CONSTRAINT ck_inventory_reserved_le_onhand CHECK (qty_reserved <= qty_on_hand)
);

-- ---------------------------------------------------------------------
-- Promotions
-- ---------------------------------------------------------------------
CREATE TABLE coupon (
    coupon_code      VARCHAR(20)  PRIMARY KEY,
    discount_pct     NUMERIC(5,2) NOT NULL CHECK (discount_pct > 0 AND discount_pct <= 90),
    max_redemptions  INT          NOT NULL CHECK (max_redemptions > 0),
    times_redeemed   INT          NOT NULL DEFAULT 0,
    valid_from       TIMESTAMPTZ  NOT NULL,
    valid_to         TIMESTAMPTZ  NOT NULL,
    CONSTRAINT ck_coupon_window      CHECK (valid_to > valid_from),
    CONSTRAINT ck_coupon_redemptions CHECK (times_redeemed BETWEEN 0 AND max_redemptions)
);

-- ---------------------------------------------------------------------
-- Orders, order lines, payments
-- ---------------------------------------------------------------------
-- "order" is an SQL reserved word, hence customer_order.
CREATE TABLE customer_order (
    order_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id          BIGINT        NOT NULL REFERENCES customer (customer_id) ON DELETE RESTRICT,
    shipping_address_id  BIGINT        NOT NULL REFERENCES customer_address (address_id) ON DELETE RESTRICT,
    coupon_code          VARCHAR(20)   REFERENCES coupon (coupon_code) ON DELETE RESTRICT,
    order_status         VARCHAR(12)   NOT NULL DEFAULT 'PENDING',
    order_date           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    subtotal             NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_amount      NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    delivery_fee         NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    -- Derived value kept consistent by the DBMS itself (generated column).
    total_amount         NUMERIC(14,2) GENERATED ALWAYS AS (subtotal - discount_amount + delivery_fee) STORED,
    CONSTRAINT ck_order_status CHECK (order_status IN
        ('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED','REFUNDED')),
    CONSTRAINT ck_order_discount CHECK (discount_amount <= subtotal)
);

CREATE TABLE order_item (
    order_id      BIGINT        NOT NULL REFERENCES customer_order (order_id) ON DELETE CASCADE,
    line_no       SMALLINT      NOT NULL CHECK (line_no > 0),
    product_id    BIGINT        NOT NULL REFERENCES product (product_id) ON DELETE RESTRICT,
    warehouse_id  SMALLINT      NOT NULL REFERENCES warehouse (warehouse_id),
    quantity      INT           NOT NULL CHECK (quantity BETWEEN 1 AND 100),
    -- Price charged at checkout. NOT a copy of product.unit_price: the catalogue
    -- price changes over time, the price on a historical invoice must not.
    unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price > 0),
    PRIMARY KEY (order_id, line_no),
    CONSTRAINT uq_order_item_product UNIQUE (order_id, product_id)
);

CREATE TABLE payment (
    payment_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        BIGINT        NOT NULL REFERENCES customer_order (order_id) ON DELETE RESTRICT,
    payment_method  VARCHAR(16)   NOT NULL,
    amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    payment_status  VARCHAR(12)   NOT NULL DEFAULT 'INITIATED',
    gateway_ref     VARCHAR(40)   NOT NULL UNIQUE,     -- idempotency key from the payment gateway
    initiated_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    settled_at      TIMESTAMPTZ,
    CONSTRAINT ck_payment_method CHECK (payment_method IN
        ('CARD','BANK_TRANSFER','USSD','WALLET','PAY_ON_DELIVERY')),
    CONSTRAINT ck_payment_status CHECK (payment_status IN
        ('INITIATED','SUCCESSFUL','FAILED','REFUNDED')),
    CONSTRAINT ck_payment_settled CHECK (settled_at IS NULL OR settled_at >= initiated_at)
);

-- ---------------------------------------------------------------------
-- Fulfilment and delivery tracking
-- ---------------------------------------------------------------------
CREATE TABLE shipment (
    shipment_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id         BIGINT      NOT NULL REFERENCES customer_order (order_id) ON DELETE RESTRICT,
    warehouse_id     SMALLINT    NOT NULL REFERENCES warehouse (warehouse_id),
    courier_name     VARCHAR(40) NOT NULL,
    tracking_number  VARCHAR(30) NOT NULL UNIQUE,
    shipment_status  VARCHAR(16) NOT NULL DEFAULT 'PACKED',
    shipped_at       TIMESTAMPTZ,
    delivered_at     TIMESTAMPTZ,
    CONSTRAINT ck_shipment_status CHECK (shipment_status IN
        ('PACKED','IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERED','RETURNED')),
    CONSTRAINT ck_shipment_dates CHECK (delivered_at IS NULL OR delivered_at >= shipped_at)
);

CREATE TABLE shipment_event (
    event_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id     BIGINT      NOT NULL REFERENCES shipment (shipment_id) ON DELETE CASCADE,
    event_status    VARCHAR(16) NOT NULL,
    event_location  VARCHAR(80) NOT NULL,
    event_time      TIMESTAMPTZ NOT NULL
);

-- ---------------------------------------------------------------------
-- Reviews and stock audit trail
-- ---------------------------------------------------------------------
CREATE TABLE product_review (
    review_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id   BIGINT   NOT NULL REFERENCES product (product_id) ON DELETE CASCADE,
    customer_id  BIGINT   NOT NULL REFERENCES customer (customer_id) ON DELETE CASCADE,
    rating       SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    review_text  VARCHAR(1000),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_one_review_per_customer UNIQUE (product_id, customer_id)
);

CREATE TABLE inventory_movement (
    movement_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id    BIGINT      NOT NULL,
    warehouse_id  SMALLINT    NOT NULL,
    qty_change    INT         NOT NULL CHECK (qty_change <> 0),
    reason        VARCHAR(12) NOT NULL CHECK (reason IN
                     ('RESTOCK','SALE','RETURN','ADJUSTMENT','RESERVE','RELEASE')),
    order_id      BIGINT      REFERENCES customer_order (order_id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- composite foreign key to the composite primary key of inventory
    FOREIGN KEY (product_id, warehouse_id) REFERENCES inventory (product_id, warehouse_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- Integrity helpers
-- ---------------------------------------------------------------------
-- Keep inventory.updated_at honest.
CREATE FUNCTION trg_touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER inventory_touch BEFORE UPDATE ON inventory
FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

-- An order may only be shipped to an address that belongs to the ordering customer.
-- (Cannot be expressed as a simple FK, so it is enforced with a trigger.)
CREATE FUNCTION trg_check_order_address() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM customer_address a
                   WHERE a.address_id = NEW.shipping_address_id
                     AND a.customer_id = NEW.customer_id) THEN
        RAISE EXCEPTION 'Address % does not belong to customer %',
              NEW.shipping_address_id, NEW.customer_id
              USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER customer_order_address_check
BEFORE INSERT OR UPDATE OF shipping_address_id, customer_id ON customer_order
FOR EACH ROW EXECUTE FUNCTION trg_check_order_address();

-- Convenience view used by the customer-service dashboard.
CREATE VIEW v_order_summary AS
SELECT o.order_id,
       o.order_date,
       c.customer_id,
       c.first_name || ' ' || c.last_name AS customer_name,
       sr.state_name                      AS ship_to_state,
       o.order_status,
       count(oi.line_no)                  AS line_count,
       o.total_amount
FROM customer_order o
JOIN customer         c  ON c.customer_id = o.customer_id
JOIN customer_address a  ON a.address_id  = o.shipping_address_id
JOIN state_region     sr ON sr.state_code = a.state_code
LEFT JOIN order_item  oi ON oi.order_id   = o.order_id
GROUP BY o.order_id, c.customer_id, sr.state_name;

-- NOTE: only the indexes implied by PK/UNIQUE constraints plus the two
-- business-rule indexes above are created here. Performance indexes are
-- added deliberately in Portfolio 2 so that before/after plans can be compared.
