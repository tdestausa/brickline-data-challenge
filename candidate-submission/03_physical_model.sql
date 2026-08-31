-- =============================================================================
-- Brickline Motors — Artifact 3: Physical Model
-- Dialect: PostgreSQL 14+
-- Principle applied: Data as a Product (#2) — these are the DDLs behind the
-- governed data products that Manufacturing, Dealer Network, and Commerce
-- publish; nothing here is queried directly by another domain except through
-- the API/view layer described in Artifact 4. (Tempting to just wire up
-- cross-schema FKs everywhere and call it a day — resisted that, mostly.)
--
-- Scope note (conceptual -> logical -> physical):
--   Conceptual: Vehicle, Recall, Ownership Event, Order — four business
--   entities identified in the Two-Tier Domain Model (01_domain_model.md).
--   Logical:    Vehicle (1) --- (0..N) Recall            via VehicleRecall (M:N)
--               Vehicle (1) --- (0..N) OwnershipEvent     (1:N, append-only history)
--               Customer (1) --- (0..N) PartsOrder        (1:N)
--               PartsOrder (N) --- (0..1) Vehicle          (self-reported, UNVALIDATED)
--   Physical:   below. Schemas map 1:1 to Tier-1 domains so ownership is
--   visible in every fully-qualified table name.
--
-- Five tables, three domains:
--   manufacturing.vehicle_master   \
--   manufacturing.recall            } Manufacturing (3 tables — recall
--   manufacturing.vehicle_recall   /   correctness needs a real M:N junction,
--                                      not a denormalized array on the vehicle)
--   dealer_network.vehicle_ownership   Dealer Network (1 table — the sub-domain
--                                      named as the Problem-9 gap in Artifact 1)
--   commerce.parts_order               Brickline Parts (1 table — Order
--                                      Fulfillment)
--
-- Could've kept going and added a Customer table, a QC table, a couple
-- more — but the brief said 3-5, and honestly five was already pushing it
-- for a 30-minute artifact. Stopped.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- for gen_random_uuid()

CREATE SCHEMA IF NOT EXISTS manufacturing;
CREATE SCHEMA IF NOT EXISTS dealer_network;
CREATE SCHEMA IF NOT EXISTS commerce;


-- =============================================================================
-- 1. manufacturing.vehicle_master
--    Owning sub-domain: Vehicle Build (source of truth for VIN existence + spec)
-- =============================================================================
CREATE TABLE manufacturing.vehicle_master (
    vin                  CHAR(17) PRIMARY KEY,               -- Classification: Internal
        -- WHY THIS CHECK: Problem 1 — Plant ERPs store VIN uppercase, Parts
        -- e-commerce stores it as the customer typed it (often lowercase).
        -- ISO 3779 mandates uppercase and excludes I/O/Q to avoid confusion
        -- with 1/0. Enforcing the format HERE, at the source-of-truth table,
        -- means every downstream consumer can trust vin is already canonical
        -- — normalization happens once, at publish time, not at every join.
        -- (Yes, that's a lot of comment for one column. It's the column
        -- that matters most in this whole file, so.)
    plant_id             TEXT NOT NULL                       -- Classification: Internal
                         CHECK (plant_id IN ('P1','P2')),
    model_code           TEXT NOT NULL,                      -- Classification: Internal
    model_year           SMALLINT NOT NULL CHECK (model_year BETWEEN 2000 AND 2100),  -- Classification: Internal
    trim                 TEXT,                                -- Classification: Internal
    build_date           DATE NOT NULL,                       -- Classification: Internal
    line_completion_ts    TIMESTAMPTZ NOT NULL,                 -- Classification: Internal
    warranty_start_date    DATE NOT NULL,                        -- Classification: Internal
    source_system         TEXT NOT NULL                        -- Classification: Internal
                         CHECK (source_system IN ('plant1_erp','plant2_erp')),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),   -- Classification: Internal  -- Problem 7: no source/timestamp metadata exists today
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),    -- Classification: Internal

    CONSTRAINT chk_vin_iso3779_format
        CHECK (vin = UPPER(vin) AND vin ~ '^[A-HJ-NPR-Z0-9]{17}$')
);

CREATE INDEX idx_vehicle_master_model_year
    ON manufacturing.vehicle_master (model_code, model_year);
    -- Rationale: recall applicability and parts-compatibility lookups both
    -- filter "which VINs are model X, year Y" before narrowing further —
    -- this is the highest-cardinality filter path into the table.

-- Sample row (from data pack, plant1_production_orders.csv PO1-2026-00000):
-- INSERT INTO manufacturing.vehicle_master VALUES
--   ('1HGBH41JXMN109186', 'P1', 'CIVIC-LX', 2026, 'LX', '2026-04-10',
--    '2026-04-10 09:01:00+00', '2026-04-10', 'plant1_erp', now(), now());


-- =============================================================================
-- 2. manufacturing.recall
--    Owning sub-domain: Recall Issuance (Problem 8 — does not exist as a
--    managed entity anywhere in Brickline today; this table is the fix)
-- =============================================================================
CREATE TABLE manufacturing.recall (
    recall_id            TEXT PRIMARY KEY,                    -- Classification: Public  -- recalls are legally disclosable (e.g. NHTSA); no reason to restrict the recall record itself
    issued_date           DATE NOT NULL,                        -- Classification: Public
    description            TEXT NOT NULL,                         -- Classification: Public
    severity              TEXT NOT NULL                        -- Classification: Public
                         CHECK (severity IN ('minor','major','critical')),
        -- WHY this enum, not plant-local values: Problem 5 — Plant 1 uses
        -- minor/major/critical, Plant 2 uses LOW/MED/HIGH for QC severity.
        -- A recall is issued once, centrally, by Manufacturing/engineering —
        -- so it gets ONE canonical vocabulary from the start rather than
        -- inheriting either plant's QC vocabulary. (QC's own severity stays
        -- plant-local in the QC data product, out of scope for this file.)
        -- Not thrilled a recall ends up with yet a THIRD severity vocabulary
        -- on top of the two plants already have, but a recall has to outlive
        -- both ERPs, so it doesn't get to borrow either one.
    status                TEXT NOT NULL DEFAULT 'active'         -- Classification: Public
                         CHECK (status IN ('active','closed')),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()      -- Classification: Internal
);

CREATE INDEX idx_recall_status ON manufacturing.recall (status) WHERE status = 'active';
    -- Rationale: partial index — "which recalls are currently active" is the
    -- query the CEO's-question join runs constantly; closed recalls (the
    -- eventual majority) never need to be scanned for it.

-- Sample row (illustrative — Problem 8: no recall data exists in the source
-- pack; this is the shape a Manufacturing-issued recall would take):
-- INSERT INTO manufacturing.recall VALUES
--   ('RCL-2026-0007', '2026-06-01', 'Front brake pad wear sensor malfunction',
--    'major', 'active', now());


-- =============================================================================
-- 3. manufacturing.vehicle_recall  (junction table)
--    Cardinality: vehicle_master (1) --- (0..N) recall, and recall (1) --- (N)
--    vehicle_master — a true M:N. A recall is issued against a build-criteria
--    range (e.g. "all CIVIC-LX built at P1 between two dates"), and a single
--    vehicle can theoretically carry more than one open recall — modeling
--    this as an array on either parent table would make "how many vehicles
--    does recall X affect" and "how many open recalls does VIN Y have" both
--    require unnesting instead of a plain join/count. Slight risk this is
--    over-engineering for a 5-table budget — but recall correctness felt
--    worth spending a table on.
-- =============================================================================
CREATE TABLE manufacturing.vehicle_recall (
    vin                  CHAR(17) NOT NULL                    -- Classification: Internal
                         REFERENCES manufacturing.vehicle_master (vin),
    recall_id             TEXT NOT NULL                          -- Classification: Public
                         REFERENCES manufacturing.recall (recall_id),
    linked_at              TIMESTAMPTZ NOT NULL DEFAULT now(),      -- Classification: Internal  -- when this VIN was determined to be in-scope for the recall

    PRIMARY KEY (vin, recall_id)
);

CREATE INDEX idx_vehicle_recall_recall_id ON manufacturing.vehicle_recall (recall_id);
    -- Rationale: PK (vin, recall_id) already serves "all recalls for this
    -- VIN" lookups left-to-right; this second index serves the inverse
    -- direction — "all VINs affected by this recall" — which is the exact
    -- access pattern recall-remediation campaigns run against.

-- Sample row:
-- INSERT INTO manufacturing.vehicle_recall VALUES
--   ('1HGBH41JXMN109186', 'RCL-2026-0007', now());


-- =============================================================================
-- 4. dealer_network.vehicle_ownership
--    Owning sub-domain: Vehicle Ownership — the specific missing sub-domain
--    named in Artifact 1 (Problem 9). Append-only history, not a single
--    current-owner row, because "who owned this VIN on the recall issue
--    date" and "who owns it now" are both real questions Dealer Network
--    needs to answer, and a trade-in re-enters a vehicle that may be resold.
-- =============================================================================
CREATE TABLE dealer_network.vehicle_ownership (
    ownership_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vin                    CHAR(17) NOT NULL,                    -- Classification: Internal
        -- NOTE ON THE MISSING FK: intentionally no REFERENCES
        -- manufacturing.vehicle_master(vin) here. Trade-In Intake accepts
        -- VINs for vehicles Brickline never built (a trader's BMW or VW —
        -- see trade_ins.csv) — those VINs will legitimately never appear in
        -- vehicle_master, and a hard FK would make ingesting a trade-in fail
        -- at the database layer for a case that is normal, not an error.
        -- Debated this one for a while, actually — a hard FK would've
        -- caught bad data earlier. Decided catching it earlier wasn't
        -- worth breaking a legitimate workflow to do it.
    owner_dealer_customer_ref TEXT NOT NULL,                       -- Classification: Confidential  -- D-XXXXX identifier; re-identifiable in combination with DMS records, though no name/email is stored in this table
    dealer_id               TEXT NOT NULL,                         -- Classification: Internal
    acquisition_type          TEXT NOT NULL                          -- Classification: Internal
                         CHECK (acquisition_type IN ('sale','trade_in')),
    sale_price_usd            NUMERIC(10,2),                          -- Classification: Confidential  -- nullable: null for a trade_in row (appraised_value lives in Trade-In Intake's own product, not duplicated here)
    finance_type              TEXT                                   -- Classification: Internal
                         CHECK (finance_type IN ('cash','loan','lease') OR finance_type IS NULL),
    effective_from             DATE NOT NULL,                          -- Classification: Internal
    ownership_status           TEXT NOT NULL DEFAULT 'current'          -- Classification: Internal
                         CHECK (ownership_status IN ('current','superseded')),
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now()        -- Classification: Internal
);

CREATE INDEX idx_vehicle_ownership_vin_current
    ON dealer_network.vehicle_ownership (vin)
    WHERE ownership_status = 'current';
    -- Rationale: partial index on the "current owner" subset — this is the
    -- hot path for the CEO's-question join (recall-affected VIN -> current
    -- owner); the full append-only history is a cold path used for
    -- point-in-time audit, not the everyday query.

CREATE INDEX idx_vehicle_ownership_customer_ref
    ON dealer_network.vehicle_ownership (owner_dealer_customer_ref);
    -- Rationale: reverse lookup — "every vehicle this dealer customer has
    -- owned" — needed by both service history and the Identity Resolution
    -- platform capability when it builds the Party/Identity Graph.

-- Sample row (VIN and dealer-customer ID chosen to match the worked example
-- in deliberate_problems.md Problem 2 — D-12345 / CU_a7b3c9 / James Patterson):
-- INSERT INTO dealer_network.vehicle_ownership VALUES
--   (gen_random_uuid(), '1HGBH41JXMN109186', 'D-12345', 'DLR-099', 'sale',
--    32000.00, 'cash', '2026-02-14', 'current', now());


-- =============================================================================
-- 5. commerce.parts_order
--    Owning sub-domain: Order Fulfillment
-- =============================================================================
CREATE TABLE commerce.parts_order (
    order_id               TEXT PRIMARY KEY,                     -- Classification: Internal
    customer_id             TEXT NOT NULL,                        -- Classification: Confidential  -- CU_xxxxxx identifier
        -- Cardinality: customer (1) --- (0..N) parts_order — one customer,
        -- many orders over time. No FK to a commerce.customer table here:
        -- that table is Parts' own Customer Account data product, out of
        -- this file's 5-table budget, and would carry an ordinary 1:N FK
        -- if included.
    vehicle_vin_provided       CHAR(17),                             -- Classification: Confidential  -- nullable, self-reported
        -- Cardinality: parts_order (N) --- (0..1) vehicle_master. NOT a
        -- foreign key, and deliberately so: this is free text a Parts
        -- customer typed into a form (Problem 1 — frequently lowercase,
        -- e.g. '1hgbh41jxmn109186'), never validated against Manufacturing
        -- at write time. Enforcing a live FK here would mean Parts' checkout
        -- flow blocks or silently drops an order the moment Manufacturing's
        -- table is unreachable — exactly the point-to-point coupling the
        -- domain-ownership principle exists to prevent. Instead this value
        -- is matched asynchronously by the platform's VIN Normalization
        -- service against manufacturing.vehicle_master; an unmatched value
        -- is a normal, expected state, not a constraint violation.
        -- This is the design call I'd defend hardest if someone pushed on it.
    total_usd                NUMERIC(10,2) NOT NULL CHECK (total_usd >= 0),  -- Classification: Confidential
    order_date               TIMESTAMPTZ NOT NULL,                     -- Classification: Internal
    status                  TEXT NOT NULL DEFAULT 'processing'         -- Classification: Internal
                         CHECK (status IN ('processing','shipped','delivered','cancelled'))
);

CREATE INDEX idx_parts_order_customer_date
    ON commerce.parts_order (customer_id, order_date);
    -- Rationale: "this customer's orders, in a date range" — the exact shape
    -- of the "bought parts last quarter" half of the CEO's question.

CREATE INDEX idx_parts_order_vin_provided
    ON commerce.parts_order (UPPER(vehicle_vin_provided))
    WHERE vehicle_vin_provided IS NOT NULL;
    -- Rationale: functional index normalizes case at query time for the
    -- (smaller) subset of orders that provided a VIN at all — lets a match
    -- job find candidates without waiting for the async normalization pass.

-- Sample row (order_date placed in the most recently completed calendar
-- quarter relative to "today," and vehicle_vin_provided is the SAME VIN as
-- the vehicle_ownership sample above — lowercase, exactly as Problem 1
-- describes — showing the full worked chain end to end):
-- INSERT INTO commerce.parts_order VALUES
--   ('ORD-2026-07-00042', 'CU_a7b3c9', '1hgbh41jxmn109186', 104.99,
--    '2026-05-20T00:00:00Z', 'delivered');


-- =============================================================================
-- Answering the CEO's question with this physical model
--
--   "How many of our recall-affected vehicles also bought replacement parts
--    last quarter?"
--
-- These 5 tables get you most of the way, but NOT all the way: the join
-- between dealer_network.vehicle_ownership.owner_dealer_customer_ref
-- (D-XXXXX) and commerce.parts_order.customer_id (CU_xxxxxx) does not exist
-- anywhere in this file, because no domain owns that link — Problem 2 is
-- exactly this gap. That link lives in platform.party_identity_link, a
-- platform-owned table (see the Self-Serve Platform capability notes),
-- deliberately outside every domain schema. Needing a 6th table that belongs
-- to neither Manufacturing, Dealer Network, nor Commerce is not a gap in
-- this model — it's the point: identity resolution is a platform capability,
-- not a fact any single domain can be made to own. Feels a little like
-- cheating to point outside this file for the answer. It's the honest one.
--
-- SELECT COUNT(DISTINCT vo.vin) AS recall_affected_owners_who_bought_parts
-- FROM dealer_network.vehicle_ownership vo
-- JOIN manufacturing.vehicle_recall vr
--   ON vr.vin = vo.vin
-- JOIN manufacturing.recall r
--   ON r.recall_id = vr.recall_id AND r.status = 'active'
-- JOIN platform.party_identity_link pil
--   ON pil.dealer_customer_ref = vo.owner_dealer_customer_ref
--  AND pil.match_status = 'confirmed'
-- JOIN commerce.parts_order po
--   ON po.customer_id = pil.commerce_customer_ref
-- WHERE vo.ownership_status = 'current'
--   AND po.order_date >= date_trunc('quarter', now()) - INTERVAL '3 months'
--   AND po.order_date <  date_trunc('quarter', now());
--
-- At Level 1 today: this query cannot be written at all. vehicle_ownership
-- and recall don't exist as tables anywhere, and there is no D-XXXXX <->
-- CU_xxxxxx link — answering the question means an analyst manually
-- exporting sales_orders.csv and orders.json, eyeballing names/emails to
-- guess at matches, and cross-referencing against whatever recall
-- information exists in someone's inbox. That is the two weeks. I've seen
-- a milder version of this exact scramble before — it's always worse than
-- whoever's asking expects going in.
-- =============================================================================
