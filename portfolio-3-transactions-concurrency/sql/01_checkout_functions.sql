-- =====================================================================
-- Portfolio 3 - 01_checkout_functions.sql
-- The SeunBaba checkout as ONE atomic unit of work.
--
-- place_order()     reserve stock + create order/lines + redeem coupon + start payment
-- settle_payment()  gateway callback: success -> PAID and stock deducted,
--                   failure -> CANCELLED and reservation/coupon released
--
-- Concurrency design
--  * Inventory rows of all products in the basket are locked with
--    SELECT ... FOR UPDATE in a FIXED ORDER (product_id, warehouse_id).
--    Two shoppers buying the same items therefore queue instead of
--    overselling, and can never deadlock on each other (no lock-order cycle).
--  * Coupon redemption is a single conditional UPDATE
--    (... WHERE times_redeemed < max_redemptions). Under READ COMMITTED the
--    second writer blocks, then PostgreSQL re-evaluates the WHERE clause on
--    the committed row version, so the limit cannot be exceeded.
--  * Any RAISE inside the function aborts the whole transaction: no partial
--    order, no orphan reservation (atomicity).
-- =====================================================================
SET search_path = seunbaba, public;

CREATE OR REPLACE FUNCTION place_order(
    p_customer_id     BIGINT,
    p_items           JSONB,                 -- [{"product_id": 12, "qty": 2}, ...]
    p_coupon_code     TEXT DEFAULT NULL,
    p_payment_method  TEXT DEFAULT 'CARD'
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_address_id   BIGINT;
    v_state        CHAR(2);
    v_order_id     BIGINT;
    v_line         SMALLINT := 0;
    v_item         RECORD;
    v_wh           SMALLINT;
    v_price        NUMERIC(12,2);
    v_subtotal     NUMERIC(14,2) := 0;
    v_discount_pct NUMERIC(5,2);
BEGIN
    -- 1. customer must be active and have a default address
    SELECT a.address_id, a.state_code INTO v_address_id, v_state
    FROM customer c JOIN customer_address a ON a.customer_id = c.customer_id AND a.is_default
    WHERE c.customer_id = p_customer_id AND c.account_status = 'ACTIVE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Customer % is not active or has no default address', p_customer_id
              USING ERRCODE = 'OJ001';
    END IF;

    -- 2. lock every stock row involved, always in the same order (deadlock avoidance)
    PERFORM 1
    FROM inventory i
    WHERE i.product_id IN (SELECT (e->>'product_id')::bigint FROM jsonb_array_elements(p_items) e)
    ORDER BY i.product_id, i.warehouse_id
    FOR UPDATE;

    -- 3. create the order header
    INSERT INTO customer_order (customer_id, shipping_address_id, order_status, delivery_fee)
    VALUES (p_customer_id, v_address_id, 'PENDING',
            CASE v_state WHEN 'LA' THEN 1500 WHEN 'OG' THEN 2000 WHEN 'FC' THEN 2500 WHEN 'RI' THEN 2500 ELSE 3500 END)
    RETURNING order_id INTO v_order_id;

    -- 4. reserve stock line by line
    FOR v_item IN
        SELECT (e->>'product_id')::bigint AS product_id, (e->>'qty')::int AS qty
        FROM jsonb_array_elements(p_items) e
        ORDER BY 1
    LOOP
        SELECT p.unit_price INTO v_price FROM product p
        WHERE p.product_id = v_item.product_id AND p.is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Product % is not available', v_item.product_id USING ERRCODE = 'OJ002';
        END IF;

        -- warehouse with enough free stock (rows are already locked by step 2)
        SELECT i.warehouse_id INTO v_wh
        FROM inventory i
        WHERE i.product_id = v_item.product_id
          AND i.qty_on_hand - i.qty_reserved >= v_item.qty
        ORDER BY i.qty_on_hand - i.qty_reserved DESC
        LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Insufficient stock for product % (requested %)', v_item.product_id, v_item.qty
                  USING ERRCODE = 'OJ003';
        END IF;

        UPDATE inventory SET qty_reserved = qty_reserved + v_item.qty
        WHERE product_id = v_item.product_id AND warehouse_id = v_wh;

        INSERT INTO inventory_movement (product_id, warehouse_id, qty_change, reason, order_id)
        VALUES (v_item.product_id, v_wh, v_item.qty, 'RESERVE', v_order_id);

        v_line := v_line + 1;
        INSERT INTO order_item (order_id, line_no, product_id, warehouse_id, quantity, unit_price)
        VALUES (v_order_id, v_line, v_item.product_id, v_wh, v_item.qty, v_price);

        v_subtotal := v_subtotal + v_item.qty * v_price;
    END LOOP;

    IF v_line = 0 THEN
        RAISE EXCEPTION 'Basket is empty' USING ERRCODE = 'OJ004';
    END IF;

    -- 5. coupon: atomic conditional increment (no read-then-write race)
    IF p_coupon_code IS NOT NULL THEN
        UPDATE coupon
           SET times_redeemed = times_redeemed + 1
         WHERE coupon_code = p_coupon_code
           AND now() BETWEEN valid_from AND valid_to
           AND times_redeemed < max_redemptions
        RETURNING discount_pct INTO v_discount_pct;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Coupon % is invalid, expired or fully redeemed', p_coupon_code
                  USING ERRCODE = 'OJ005';
        END IF;
    END IF;

    UPDATE customer_order
       SET subtotal        = v_subtotal,
           coupon_code     = p_coupon_code,
           discount_amount = round(v_subtotal * coalesce(v_discount_pct, 0) / 100, 2)
     WHERE order_id = v_order_id;

    -- 6. start payment (gateway_ref doubles as idempotency key)
    INSERT INTO payment (order_id, payment_method, amount, payment_status, gateway_ref)
    SELECT v_order_id, p_payment_method, total_amount, 'INITIATED', 'PSK-LIVE-' || v_order_id
    FROM customer_order WHERE order_id = v_order_id;

    RETURN v_order_id;
END $$;


CREATE OR REPLACE FUNCTION settle_payment(p_order_id BIGINT, p_success BOOLEAN)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    -- lock the order header first: two callbacks for the same order are serialised
    SELECT order_status INTO v_status FROM customer_order WHERE order_id = p_order_id FOR UPDATE;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Order % not found', p_order_id USING ERRCODE = 'OJ006';
    ELSIF v_status <> 'PENDING' THEN
        RETURN 'IGNORED (order already ' || v_status || ')';      -- idempotent webhook
    END IF;

    IF p_success THEN
        UPDATE payment SET payment_status = 'SUCCESSFUL', settled_at = now()
         WHERE order_id = p_order_id AND payment_status = 'INITIATED';
        -- reservation becomes a real stock deduction
        UPDATE inventory i
           SET qty_on_hand  = i.qty_on_hand  - oi.quantity,
               qty_reserved = i.qty_reserved - oi.quantity
          FROM order_item oi
         WHERE oi.order_id = p_order_id
           AND i.product_id = oi.product_id AND i.warehouse_id = oi.warehouse_id;
        INSERT INTO inventory_movement (product_id, warehouse_id, qty_change, reason, order_id)
        SELECT product_id, warehouse_id, -quantity, 'SALE', order_id FROM order_item WHERE order_id = p_order_id;
        UPDATE customer_order SET order_status = 'PAID' WHERE order_id = p_order_id;
        RETURN 'PAID';
    ELSE
        UPDATE payment SET payment_status = 'FAILED'
         WHERE order_id = p_order_id AND payment_status = 'INITIATED';
        UPDATE inventory i
           SET qty_reserved = i.qty_reserved - oi.quantity
          FROM order_item oi
         WHERE oi.order_id = p_order_id
           AND i.product_id = oi.product_id AND i.warehouse_id = oi.warehouse_id;
        INSERT INTO inventory_movement (product_id, warehouse_id, qty_change, reason, order_id)
        SELECT product_id, warehouse_id, -quantity, 'RELEASE', order_id FROM order_item WHERE order_id = p_order_id;
        UPDATE coupon c SET times_redeemed = c.times_redeemed - 1
          FROM customer_order o WHERE o.order_id = p_order_id AND c.coupon_code = o.coupon_code;
        UPDATE customer_order SET order_status = 'CANCELLED' WHERE order_id = p_order_id;
        RETURN 'CANCELLED';
    END IF;
END $$;
