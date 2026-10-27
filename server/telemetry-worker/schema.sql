-- CruiseLAN telemetry storage.
--
-- Two tables rather than one wide one: a report is the unit the app uploads (one device,
-- one window), and measurements hang off it. That makes "how many devices reported" and
-- "what did they measure" both cheap, and lets a report be deleted whole.
--
-- There is intentionally nothing here that identifies a person. install_id is a pseudonym
-- that rotates every 14 days on the device; see docs/decisions/telemetry.md.

CREATE TABLE IF NOT EXISTS reports (
    id              TEXT PRIMARY KEY,
    install_id      TEXT NOT NULL,
    app_version     TEXT NOT NULL,
    system_version  TEXT NOT NULL,
    device_class    TEXT NOT NULL,
    window_start    TEXT NOT NULL,
    window_end      TEXT NOT NULL,
    received_at     TEXT NOT NULL,
    schema_version  INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS reports_received_at ON reports (received_at);
CREATE INDEX IF NOT EXISTS reports_app_version ON reports (app_version);

CREATE TABLE IF NOT EXISTS measurements (
    report_id   TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
    signal      TEXT NOT NULL,
    dimension   TEXT,
    count       INTEGER NOT NULL,
    sum         REAL NOT NULL,
    min         REAL NOT NULL,
    max         REAL NOT NULL,
    -- JSON array of histogram bucket counts, matching Aggregate.bucketUpperBounds.
    buckets     TEXT
);

CREATE INDEX IF NOT EXISTS measurements_signal ON measurements (signal, dimension);
CREATE INDEX IF NOT EXISTS measurements_report ON measurements (report_id);
