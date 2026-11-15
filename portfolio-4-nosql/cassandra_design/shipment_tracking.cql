-- =====================================================================
-- Portfolio 4 - Wide-column (Apache Cassandra) DESIGN for courier tracking.
-- STATUS: design artefact only. It was NOT executed in this portfolio
-- (no Cassandra cluster was available). It shows query-first modelling
-- for the highest-volume, append-only SeunBaba data: courier scan events
-- (1.12 M rows today, growing roughly 4 rows per order).
-- =====================================================================

CREATE KEYSPACE IF NOT EXISTS seunbaba_tracking
  WITH replication = {'class': 'NetworkTopologyStrategy', 'lagos_dc': 3, 'abuja_dc': 2};

-- Query 1: "show every scan for tracking number X, newest first" (customer tracking page)
-- Partition = one parcel, so a single-partition read with events already sorted on disk.
CREATE TABLE IF NOT EXISTS events_by_tracking_number (
    tracking_number  text,
    event_time       timestamp,
    event_status     text,
    event_location   text,
    courier_name     text,
    order_id         bigint,
    PRIMARY KEY ((tracking_number), event_time)
) WITH CLUSTERING ORDER BY (event_time DESC)
  AND default_time_to_live = 63072000;          -- keep 2 years, then expire automatically

-- Query 2: "all parcels a courier scanned in a hub on a given day" (courier SLA dashboard)
-- Composite partition key (courier, day) bounds partition size (one day of scans) and
-- spreads writes across the cluster instead of creating one hot partition per courier.
CREATE TABLE IF NOT EXISTS events_by_courier_day (
    courier_name     text,
    scan_date        date,
    event_time       timestamp,
    tracking_number  text,
    event_status     text,
    event_location   text,
    PRIMARY KEY ((courier_name, scan_date), event_time, tracking_number)
) WITH CLUSTERING ORDER BY (event_time ASC, tracking_number ASC);

-- Writes go to BOTH tables (denormalised by design: one table per query).
-- Typical consistency: write LOCAL_QUORUM (2 of 3 Lagos replicas), read LOCAL_ONE
-- for the tracking page (a scan that is a few ms stale is acceptable).
--
-- INSERT INTO events_by_tracking_number (tracking_number, event_time, event_status, event_location, courier_name, order_id)
-- VALUES ('OJX000245000', '2026-10-30 09:15:00+0100', 'OUT_FOR_DELIVERY', 'Lekki', 'GIG Logistics', 245000);
-- SELECT * FROM events_by_tracking_number WHERE tracking_number = 'OJX000245000';
