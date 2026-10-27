# CruiseLAN telemetry backend

Answers the open question from the cruise notes: *where does telemetry go, and how do I look
at it?*

- **Where:** a Cloudflare Worker that validates reports and writes them to D1 (Cloudflare's
  SQLite). Free tier, no server to maintain.
- **How you read it:** SQL, either from the terminal (`wrangler d1 execute`) or the D1 console
  in the Cloudflare dashboard. The app's own **Insights** page shows the same signals for the
  local device, live, with no backend at all.

Design rationale, including what was rejected and why there's no API key, is in
[`docs/decisions/telemetry.md`](../../docs/decisions/telemetry.md).

## Deploy

Requires a free Cloudflare account and `npm i -g wrangler`.

```bash
cd server/telemetry-worker

wrangler login

# 1. Create the database, then paste the printed database_id into wrangler.toml.
wrangler d1 create cruiselan-telemetry

# 2. Create the tables.
wrangler d1 execute cruiselan-telemetry --remote --file=./schema.sql

# 3. Ship it. Prints a https://cruiselan-telemetry.<subdomain>.workers.dev URL.
wrangler deploy
```

Then point the app at it. In Xcode, add the Worker URL as the `CruiseLANTelemetryEndpoint`
Info.plist key on the `iso_cruise_app` target:

```
CruiseLANTelemetryEndpoint = https://cruiselan-telemetry.<subdomain>.workers.dev
```

Until that key is set the app records locally and uploads nothing — so the Insights page works
immediately, and no data leaves any device until you deliberately turn this on. The user must
*also* enable sharing in the app; it defaults to off.

### Recommended: turn on rate limiting

The endpoint has no credential by design. Add a rate limiting rule in the Cloudflare
dashboard (Security → WAF → Rate limiting rules) of roughly **20 requests per minute per IP**
on the Worker route. A legitimate device sends one report per six hours, so this is orders of
magnitude above real use and still caps abuse.

## Reading the data

Everything below is read-only. Add `--remote` to hit the deployed database.

**Which transport actually carries traffic?** The headline question the LAN work exists to
answer.

```sql
SELECT dimension, SUM(count) AS links
FROM measurements
WHERE signal = 'linkConnectedByTier'
GROUP BY dimension
ORDER BY links DESC;
```

**Which discovery tiers are failing, and how often?** Compare against the above — a tier with
many failures and no successes is a tier to drop.

```sql
SELECT dimension, SUM(count) AS failures
FROM measurements
WHERE signal = 'tierAttemptFailed'
GROUP BY dimension
ORDER BY failures DESC;
```

**Does battery saver hurt discovery?** The hunch from the notes. Compare the two averages;
a materially lower figure for `lowPowerOn` confirms it.

```sql
SELECT dimension,
       SUM(sum) / NULLIF(SUM(count), 0) AS avg_peers_visible,
       SUM(count) AS samples
FROM measurements
WHERE signal = 'peersVisibleByPowerMode'
GROUP BY dimension;
```

**What blocks discovery when it fails?**

```sql
SELECT dimension, SUM(count) AS occurrences
FROM measurements
WHERE signal = 'pathProbeOutcome'
GROUP BY dimension
ORDER BY occurrences DESC;
```

**How far does the mesh actually reach?**

```sql
SELECT SUM(sum) / NULLIF(SUM(count), 0) AS avg_hops, MAX(max) AS max_hops
FROM measurements
WHERE signal = 'announceHopCount';
```

**How many devices are reporting, by version?**

```sql
SELECT app_version, COUNT(DISTINCT install_id) AS devices, COUNT(*) AS reports
FROM reports
GROUP BY app_version
ORDER BY app_version DESC;
```

Note that `install_id` rotates every 14 days, so `COUNT(DISTINCT install_id)` is an upper
bound on devices over long periods, not an exact count. That's deliberate.

## Housekeeping

Old reports have no value once the version they describe is retired. Trim periodically:

```sql
DELETE FROM reports WHERE received_at < date('now', '-90 days');
DELETE FROM measurements WHERE report_id NOT IN (SELECT id FROM reports);
```

## Keeping the vocabularies in step

`src/index.js` mirrors the `SIGNALS` and `DIMENSIONS` sets from
`iso_cruise_app/Telemetry/TelemetrySignal.swift`. Unknown names are **dropped, not rejected**,
so a newer app build still contributes its known signals before this Worker is updated — but
new signals won't be stored until you add them here too.
