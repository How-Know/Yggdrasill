import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

type JsonObject = Record<string, unknown>;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function fail(error: string, status = 400): Response {
  return json({ ok: false, error }, status);
}

function stringValue(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function bearerToken(req: Request): string {
  const value = req.headers.get('Authorization') ?? '';
  return value.toLowerCase().startsWith('bearer ') ? value.slice(7).trim() : '';
}

function randomPairingCode(): string {
  const max = 0x1_0000_0000;
  const limit = max - (max % 1_000_000);
  const value = new Uint32Array(1);
  do crypto.getRandomValues(value); while (value[0] >= limit);
  return value[0].toString().padStart(6, '0');
}

function randomDeviceToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join('');
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, '0')
  ).join('');
}

function rpcStatus(result: JsonObject): number {
  switch (result.error) {
    case 'invalid_token':
      return 401;
    case 'pairing_pending':
      return 202;
    case 'pairing_not_found':
    case 'pairing_expired':
      return 404;
    default:
      return result.ok === false ? 400 : 200;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') return fail('method_not_allowed', 405);

  let body: JsonObject;
  try {
    body = await req.json() as JsonObject;
  } catch {
    return fail('invalid_json');
  }

  const action = stringValue(body.action);
  if (!action) return fail('action_required');

  // This client and its key exist only inside the Edge Function runtime.
  const admin = createAdminClient();

  try {
    if (action === 'begin_pairing') {
      const deviceId = stringValue(body.device_id);
      const deviceName = stringValue(body.device_name);
      if (!deviceId || !deviceName) return fail('invalid_request');

      for (let attempt = 0; attempt < 5; attempt++) {
        const code = randomPairingCode();
        const { data, error } = await admin.rpc('kiosk_begin_pairing', {
          p_device_id: deviceId,
          p_device_name: deviceName,
          p_code: code,
        });
        if (!error) {
          const result = data as JsonObject;
          return json(result, rpcStatus(result));
        }
        if (error.code !== '23505') throw error;
      }
      return fail('pairing_code_unavailable', 503);
    }

    if (action === 'poll_pairing') {
      const deviceId = stringValue(body.device_id);
      const code = stringValue(body.code);
      if (!deviceId || !/^\d{6}$/.test(code)) return fail('invalid_request');

      const token = randomDeviceToken();
      const tokenHash = await sha256Hex(token);
      const { data, error } = await admin.rpc('kiosk_claim_pairing', {
        p_device_id: deviceId,
        p_code: code,
        p_token_hash: tokenHash,
      });
      if (error) throw error;
      const result = data as JsonObject;
      if (result.ok !== true) return json(result, rpcStatus(result));
      return json({ ...result, token });
    }

    const token = stringValue(body.token) ||
      stringValue(req.headers.get('X-Kiosk-Token')) ||
      bearerToken(req);
    if (!token) return fail('token_required', 401);
    const tokenHash = await sha256Hex(token);

    if (action === 'bootstrap') {
      const { data, error } = await admin.rpc('kiosk_bootstrap', {
        p_token_hash: tokenHash,
      });
      if (error) throw error;
      const result = data as JsonObject;
      return json(result, rpcStatus(result));
    }

    if (action === 'list_today') {
      const { data, error } = await admin.rpc('kiosk_list_today', {
        p_token_hash: tokenHash,
      });
      if (error) throw error;
      const result = data as JsonObject;
      return json(result, rpcStatus(result));
    }

    if (action === 'search_students') {
      const query = stringValue(body.query);
      const { data, error } = await admin.rpc('kiosk_search_students', {
        p_token_hash: tokenHash,
        p_query: query,
      });
      if (error) throw error;
      const result = data as JsonObject;
      return json(result, rpcStatus(result));
    }

    if (action === 'check_in') {
      const studentId = stringValue(body.student_id);
      const requestId = stringValue(body.request_id);
      const pin = typeof body.pin === 'string' ? body.pin : null;
      if (
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
          .test(studentId) ||
        !requestId
      ) {
        return fail('invalid_request');
      }

      const { data, error } = await admin.rpc('kiosk_check_in', {
        p_token_hash: tokenHash,
        p_student_id: studentId,
        p_pin: pin,
        p_request_id: requestId,
        p_walk_in: body.walk_in === true,
      });
      if (error) throw error;
      const result = data as JsonObject;
      return json(result, rpcStatus(result));
    }

    return fail('unknown_action', 404);
  } catch (error) {
    console.error('[kiosk_api]', error instanceof Error ? error.message : String(error));
    return fail('server_error', 500);
  }
});
