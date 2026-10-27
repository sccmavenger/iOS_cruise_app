/**
 * CruiseLAN telemetry ingest.
 *
 * Accepts aggregated, pseudonymous measurements from the app and writes them to D1.
 *
 * Security posture: there is no API key, because the client is an iOS app and anything
 * compiled into it is extractable. Instead this endpoint is cheap to abuse and useless to
 * abuse: it accepts exactly one schema, rejects any signal or dimension name it doesn't
 * already know, caps the body, and relies on Cloudflare's per-IP rate limiting in front.
 * The worst an attacker achieves is adding noise to aggregate counters, so no decision
 * should ever rest on a single installId's numbers.
 *
 * See docs/decisions/telemetry.md.
 */

const MAX_BODY_BYTES = 64 * 1024;
const MAX_MEASUREMENTS = 512;
const BUCKET_COUNT = 10; // 9 upper bounds + 1 overflow, must match Aggregate.bucketUpperBounds

/**
 * The closed vocabularies, mirrored from TelemetrySignal.swift and kept in step by hand.
 * Anything outside these is dropped rather than stored, so a malformed or hostile client
 * can't create new series.
 */
const SIGNALS = new Set([
  'linkConnectedByTier', 'announceHopCount', 'timeToFirstPeer', 'reachableContacts',
  'tierAttemptFailed', 'pathProbeOutcome', 'peersVisibleByPowerMode', 'capabilityUnavailable',
  'chatSendAttempt', 'chatHeldForAway', 'packetRejected', 'rateLimitHit',
  'linkDropped', 'linkLifetime', 'reconnectLatency',
  'matchStarted', 'matchEnded', 'moveRoundTrip', 'stateResync',
]);

const DIMENSIONS = new Set([
  'multipeer', 'lanBonjour', 'lanBroadcast', 'lanJoinCode',
  'wifiUnavailable', 'bluetoothUnavailable', 'bluetoothUnauthorized', 'localNetworkDenied',
  'multicastBlocked', 'clientIsolation', 'captivePortal', 'lowPowerMode',
  'notificationsDenied', 'ok',
  'success', 'failure', 'timeout', 'noPeers', 'refused',
  'lowPowerOn', 'lowPowerOff',
  'badSignature', 'unknownSender', 'stale', 'duplicate', 'oversized', 'blockedSender',
  'connectionLost', 'localSuspend',
  'completed', 'abandoned',
]);

/** Version strings are shown in dashboards, so keep them short and boring. */
const SHORT_TEXT = /^[\w\s.()\-+]{1,64}$/;
const UUID_LIKE = /^[0-9a-fA-F-]{8,64}$/;

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }
    if (request.method !== 'POST') {
      return json({ error: 'method not allowed' }, 405);
    }

    const length = Number(request.headers.get('content-length') ?? '0');
    if (length > MAX_BODY_BYTES) {
      return json({ error: 'body too large' }, 413);
    }

    let payload;
    try {
      const text = await request.text();
      if (text.length > MAX_BODY_BYTES) return json({ error: 'body too large' }, 413);
      payload = JSON.parse(text);
    } catch {
      return json({ error: 'malformed json' }, 400);
    }

    const problem = validate(payload);
    if (problem) return json({ error: problem }, 400);

    // Keep only measurements whose names we recognise. Dropping unknown names rather than
    // rejecting the whole report means a newer app version still contributes its known
    // signals before this Worker is updated.
    const accepted = payload.measurements.filter(
      (m) => SIGNALS.has(m.signal) && (m.dimension == null || DIMENSIONS.has(m.dimension))
    );
    if (accepted.length === 0) return json({ error: 'no known measurements' }, 400);

    const receivedAt = new Date().toISOString();
    const reportId = crypto.randomUUID();

    try {
      // One statement per measurement, batched so the whole report lands or none of it does.
      const statements = [
        env.DB.prepare(
          `INSERT INTO reports (id, install_id, app_version, system_version, device_class,
                                window_start, window_end, received_at, schema_version)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
        ).bind(
          reportId, payload.installId, payload.appVersion, payload.systemVersion,
          payload.deviceClass, payload.windowStart, payload.windowEnd, receivedAt,
          payload.schema ?? 1
        ),
        ...accepted.map((m) =>
          env.DB.prepare(
            `INSERT INTO measurements (report_id, signal, dimension, count, sum, min, max, buckets)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
          ).bind(
            reportId, m.signal, m.dimension ?? null,
            m.count, m.sum, m.min, m.max, JSON.stringify(m.buckets ?? [])
          )
        ),
      ];
      await env.DB.batch(statements);
    } catch (error) {
      // Don't echo the database error back to the client.
      console.error('insert failed', error);
      return json({ error: 'storage failure' }, 500);
    }

    return json({ ok: true, stored: accepted.length }, 202);
  },
};

/** Returns a reason string when the payload isn't usable, or null when it is. */
function validate(payload) {
  if (typeof payload !== 'object' || payload === null) return 'not an object';
  if (!UUID_LIKE.test(String(payload.installId ?? ''))) return 'bad installId';
  for (const field of ['appVersion', 'systemVersion', 'deviceClass']) {
    if (!SHORT_TEXT.test(String(payload[field] ?? ''))) return `bad ${field}`;
  }
  for (const field of ['windowStart', 'windowEnd']) {
    const value = Date.parse(payload[field] ?? '');
    if (Number.isNaN(value)) return `bad ${field}`;
  }
  if (!Array.isArray(payload.measurements)) return 'measurements not an array';
  if (payload.measurements.length > MAX_MEASUREMENTS) return 'too many measurements';

  for (const m of payload.measurements) {
    if (typeof m !== 'object' || m === null) return 'bad measurement';
    if (!Number.isInteger(m.count) || m.count < 0) return 'bad count';
    for (const field of ['sum', 'min', 'max']) {
      if (typeof m[field] !== 'number' || !Number.isFinite(m[field])) return `bad ${field}`;
    }
    if (m.buckets != null) {
      if (!Array.isArray(m.buckets) || m.buckets.length > BUCKET_COUNT) return 'bad buckets';
      if (!m.buckets.every((b) => Number.isInteger(b) && b >= 0)) return 'bad buckets';
    }
    if (m.dimension != null && typeof m.dimension !== 'string') return 'bad dimension';
  }
  return null;
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...corsHeaders() },
  });
}

function corsHeaders() {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'POST, OPTIONS',
    'access-control-allow-headers': 'content-type',
  };
}
