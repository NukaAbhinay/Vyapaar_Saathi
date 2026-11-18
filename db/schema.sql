-- Paytm Vyaapar Saathi — production schema (PostgreSQL 14+)
--
-- NOT used by the prototype. The demo runs on an embedded synthetic dataset so it can be opened
-- with no install. This file is the target design for a real deployment: it shows where each
-- screen's data comes from, and where the consent and audit trail live.
--
-- Design rules carried over from the prototype:
--   * every customer message is attributable to a consent row and an audit row
--   * phone numbers are stored once, never duplicated into logs
--   * amounts are integer paise, never floats

CREATE TABLE merchants (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_name       text NOT NULL,
  owner_name      text NOT NULL,
  phone_e164      text NOT NULL UNIQUE,
  upi_vpa         text,                          -- collection only; no PIN, no card, no bank credential
  language        text NOT NULL DEFAULT 'te',    -- te | hi | en
  timezone        text NOT NULL DEFAULT 'Asia/Kolkata',
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE customers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  name            text NOT NULL,
  phone_e164      text NOT NULL,
  first_seen      date NOT NULL,
  last_seen       date,
  opted_out       boolean NOT NULL DEFAULT false,
  dispute_open    boolean NOT NULL DEFAULT false, -- blocks reminders outright
  hardship_flag   boolean NOT NULL DEFAULT false, -- blocks reminders, notifies the owner
  deleted_at      timestamptz,                    -- soft delete for erasure requests
  UNIQUE (merchant_id, phone_e164)
);

-- One row per permission, per purpose. Withdrawal is a new row, never an update:
-- the history is the evidence.
CREATE TABLE consent_events (
  id              bigserial PRIMARY KEY,
  customer_id     uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  purpose         text NOT NULL CHECK (purpose IN ('receipt','reminder','stock_alert','feedback')),
  granted         boolean NOT NULL,
  language        text NOT NULL,
  channel         text NOT NULL DEFAULT 'whatsapp',
  recorded_at     timestamptz NOT NULL DEFAULT now(),
  source          text NOT NULL                    -- counter | receipt_qr | owner_manual
);
CREATE INDEX ON consent_events (customer_id, purpose, recorded_at DESC);

CREATE TABLE bills (
  id              bigserial PRIMARY KEY,
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  customer_id     uuid REFERENCES customers(id),
  bill_no         text NOT NULL,
  billed_at       timestamptz NOT NULL,
  total_paise     bigint NOT NULL,
  paid_paise      bigint NOT NULL DEFAULT 0,
  channel         text NOT NULL,                   -- upi | cash | card | udhaar
  is_tax_invoice  boolean NOT NULL DEFAULT false    -- prototype receipts are informational only
);
CREATE INDEX ON bills (merchant_id, billed_at DESC);

CREATE TABLE bill_items (
  bill_id         bigint NOT NULL REFERENCES bills(id) ON DELETE CASCADE,
  product_id      uuid NOT NULL,
  qty             numeric(10,3) NOT NULL,
  unit            text NOT NULL,
  rate_paise      bigint NOT NULL,
  PRIMARY KEY (bill_id, product_id)
);

CREATE TABLE udhaar_entries (
  id              bigserial PRIMARY KEY,
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  customer_id     uuid NOT NULL REFERENCES customers(id),
  amount_paise    bigint NOT NULL,                 -- positive = owes, negative = repaid
  entry_date      date NOT NULL,
  note            text
);
CREATE INDEX ON udhaar_entries (merchant_id, customer_id, entry_date);

CREATE TABLE products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  name            text NOT NULL,
  category        text NOT NULL,                   -- perishable | staple | packaged | ...
  unit            text NOT NULL,
  stock_qty       numeric(10,3) NOT NULL DEFAULT 0,
  reorder_cover   integer NOT NULL DEFAULT 10      -- days of cover; 2 for perishables
);

CREATE TABLE dealers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  name            text NOT NULL,
  area            text,
  phone_e164      text
);

CREATE TABLE dealer_quotes (
  id              bigserial PRIMARY KEY,
  dealer_id       uuid NOT NULL REFERENCES dealers(id) ON DELETE CASCADE,
  product_id      uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  rate_paise      bigint NOT NULL,
  pack_size       numeric(10,3) NOT NULL,
  credit_days     integer NOT NULL DEFAULT 0,      -- a rate on credit is not the same rate
  quoted_at       timestamptz NOT NULL DEFAULT now()
);

-- What customers asked for that the shop does not stock. The waitlist is derived from this.
CREATE TABLE enquiries (
  id              bigserial PRIMARY KEY,
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  customer_id     uuid REFERENCES customers(id),
  product_name    text NOT NULL,
  qty             numeric(10,3),
  asked_at        timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL DEFAULT 'open'     -- open | sourced | fulfilled | dropped
);

CREATE TABLE waitlist (
  id              bigserial PRIMARY KEY,
  enquiry_id      bigint NOT NULL REFERENCES enquiries(id) ON DELETE CASCADE,
  customer_id     uuid NOT NULL REFERENCES customers(id),
  notified_at     timestamptz,
  hold_until      date                             -- short hold once stock arrives
);

-- Every customer-facing message, drafted and sent or not. The owner approval lives here.
CREATE TABLE messages (
  id              bigserial PRIMARY KEY,
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  customer_id     uuid REFERENCES customers(id),
  purpose         text NOT NULL,
  language        text NOT NULL,
  body            text NOT NULL,
  drafted_by      text NOT NULL,                   -- template | model:<name>
  approved_by     text,                            -- owner identity, null until approved
  sent_at         timestamptz,
  blocked_reason  text,                            -- consent | window | cap | dispute | hardship
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON messages (merchant_id, created_at DESC);

-- Append-only. Nothing in the app may update or delete these rows.
CREATE TABLE audit_log (
  id              bigserial PRIMARY KEY,
  merchant_id     uuid NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  actor           text NOT NULL,                   -- owner | system | agent
  action          text NOT NULL,                   -- consent.granted | message.approved | data.exported
  subject         text,
  detail          jsonb NOT NULL DEFAULT '{}'::jsonb,
  at              timestamptz NOT NULL DEFAULT now()
);

-- Weekly reminder cap and send window are enforced in application code and verifiable here:
CREATE VIEW reminders_last_7_days AS
SELECT merchant_id, customer_id, count(*) AS sent
FROM messages
WHERE purpose = 'reminder' AND sent_at > now() - interval '7 days'
GROUP BY merchant_id, customer_id;
