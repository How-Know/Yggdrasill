import { createAdminClient, createUserClient } from '../_shared/supabase.ts';

type Json = Record<string, unknown>;
type DeliveryRow = {
  id: string;
  event_id: string;
  device_id: string;
  attempts: number;
};
type EventRow = {
  id: string;
  attendance_id: string;
  student_id: string;
  student_name: string;
  event_type: 'arrival' | 'departure';
  occurred_at: string;
};
type DeviceRow = {
  id: string;
  device_token: string;
  bundle_id: string;
  environment: 'development' | 'production' | 'unknown';
};

const encoder = new TextEncoder();
let cachedProviderToken: { value: string; createdAt: number } | null = null;

function json(body: Json, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function base64Url(input: Uint8Array | string): string {
  const bytes = typeof input === 'string' ? encoder.encode(input) : input;
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/g, '');
}

function decodePem(pem: string): Uint8Array {
  const normalized = pem.replaceAll('\\n', '\n');
  const body = normalized
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  const binary = atob(body);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedProviderToken && now - cachedProviderToken.createdAt < 45 * 60) {
    return cachedProviderToken.value;
  }
  const keyId = Deno.env.get('APNS_KEY_ID')?.trim() ?? '';
  const teamId = Deno.env.get('APNS_TEAM_ID')?.trim() ?? '';
  const privateKey = Deno.env.get('APNS_KEY_P8')?.trim() ?? '';
  if (!keyId || !teamId || !privateKey) {
    throw new Error('APNs secrets are not configured');
  }
  const key = await crypto.subtle.importKey(
    'pkcs8',
    decodePem(privateKey),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const header = base64Url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = base64Url(JSON.stringify({ iss: teamId, iat: now }));
  const signingInput = `${header}.${claims}`;
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      encoder.encode(signingInput),
    ),
  );
  const value = `${signingInput}.${base64Url(signature)}`;
  cachedProviderToken = { value, createdAt: now };
  return value;
}

function apnsHost(environment: DeviceRow['environment']): string {
  return environment === 'production'
    ? 'https://api.push.apple.com'
    : 'https://api.sandbox.push.apple.com';
}

function alternateEnvironment(
  environment: DeviceRow['environment'],
): DeviceRow['environment'] {
  return environment === 'production' ? 'development' : 'production';
}

async function sendToApns(
  event: EventRow,
  device: DeviceRow,
  environment: DeviceRow['environment'],
): Promise<{ ok: boolean; status: number; reason: string; apnsId: string }> {
  const token = await providerToken();
  const bundleId = device.bundle_id ||
    Deno.env.get('APNS_WATCH_BUNDLE_ID') ||
    'com.beleunu.yggdrasill.watchkitapp';
  const isArrival = event.event_type === 'arrival';
  const payload = {
    aps: {
      alert: {
        title: isArrival ? '학생 등원' : '학생 하원',
        body: `${event.student_name} 학생이 ${
          isArrival ? '등원' : '하원'
        }했습니다.`,
      },
      sound: 'default',
      'interruption-level': 'time-sensitive',
      'thread-id': 'attendance',
      category: 'ATTENDANCE',
    },
    eventId: event.id,
    attendanceId: event.attendance_id,
    studentId: event.student_id,
    eventType: event.event_type,
    occurredAt: event.occurred_at,
  };
  const response = await fetch(
    `${apnsHost(environment)}/3/device/${device.device_token}`,
    {
      method: 'POST',
      headers: {
        authorization: `bearer ${token}`,
        'apns-topic': bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': `${Math.floor(Date.now() / 1000) + 3600}`,
        'apns-collapse-id': `attendance-${event.id}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(payload),
    },
  );
  let reason = '';
  if (!response.ok) {
    try {
      reason = String((await response.json())?.reason ?? '');
    } catch (_) {
      reason = await response.text();
    }
  }
  return {
    ok: response.ok,
    status: response.status,
    reason,
    apnsId: response.headers.get('apns-id') ?? '',
  };
}

function retryDelaySeconds(attempts: number): number {
  return Math.min(1800, Math.max(15, 15 * 2 ** Math.min(attempts, 7)));
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'method' }, 405);
  if (
    !Deno.env.get('APNS_KEY_ID') ||
    !Deno.env.get('APNS_TEAM_ID') ||
    !Deno.env.get('APNS_KEY_P8')
  ) {
    return json({ ok: false, error: 'apns_not_configured' }, 503);
  }

  const admin = createAdminClient();
  let input: Record<string, unknown> = {};
  try {
    input = await req.json();
  } catch (_) {
    input = {};
  }

  if (input.action === 'test') {
    const academyId = String(input.academyId ?? '').trim();
    const userClient = createUserClient(req);
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user || !academyId) {
      return json({ ok: false, error: 'unauthorized' }, 401);
    }
    const { data: membership } = await userClient
      .from('memberships')
      .select('academy_id')
      .eq('academy_id', academyId)
      .eq('user_id', userData.user.id)
      .maybeSingle();
    if (!membership) return json({ ok: false, error: 'not_a_member' }, 403);

    const { data: rawDevices, error: deviceError } = await admin
      .from('watch_push_devices')
      .select('id,device_token,bundle_id,environment')
      .eq('academy_id', academyId)
      .eq('user_id', userData.user.id)
      .eq('enabled', true);
    if (deviceError) return json({ ok: false, error: deviceError.message }, 500);
    const devices = (rawDevices ?? []) as DeviceRow[];
    if (devices.length === 0) {
      return json({ ok: false, error: 'no_registered_watch' }, 404);
    }
    const testEvent: EventRow = {
      id: crypto.randomUUID(),
      attendance_id: crypto.randomUUID(),
      student_id: crypto.randomUUID(),
      student_name: '테스트',
      event_type: 'arrival',
      occurred_at: new Date().toISOString(),
    };
    const results = [];
    for (const device of devices) {
      let environment = device.environment === 'unknown'
        ? 'production'
        : device.environment;
      let result = await sendToApns(testEvent, device, environment);
      if (!result.ok && result.reason === 'BadDeviceToken') {
        environment = alternateEnvironment(environment);
        result = await sendToApns(testEvent, device, environment);
        if (result.ok) {
          await admin.from('watch_push_devices').update({
            environment,
            updated_at: new Date().toISOString(),
          }).eq('id', device.id);
        }
      }
      results.push({
        deviceId: device.id,
        ok: result.ok,
        status: result.status,
        reason: result.reason,
      });
    }
    return json({
      ok: results.some((result) => result.ok),
      tested: results.length,
      results,
    });
  }

  // 이전 invocation이 claim 직후 종료된 경우 영구적으로 sending에 멈추지 않게 복구한다.
  await admin
    .from('watch_push_deliveries')
    .update({
      status: 'retry',
      next_attempt_at: new Date().toISOString(),
      last_error: 'stale_sending_recovered',
      updated_at: new Date().toISOString(),
    })
    .eq('status', 'sending')
    .lt('updated_at', new Date(Date.now() - 2 * 60 * 1000).toISOString());

  const { data: rawDeliveries, error: deliveryError } = await admin
    .from('watch_push_deliveries')
    .select('id,event_id,device_id,attempts')
    .in('status', ['pending', 'retry'])
    .lte('next_attempt_at', new Date().toISOString())
    .order('created_at')
    .limit(50);
  if (deliveryError) return json({ ok: false, error: deliveryError.message }, 500);
  const deliveries = (rawDeliveries ?? []) as DeliveryRow[];
  if (deliveries.length === 0) return json({ ok: true, sent: 0 });

  const eventIds = [...new Set(deliveries.map((row) => row.event_id))];
  const deviceIds = [...new Set(deliveries.map((row) => row.device_id))];
  const [
    { data: rawEvents, error: eventError },
    { data: rawDevices, error: deviceError },
  ] = await Promise.all([
    admin.from('watch_push_events').select(
      'id,attendance_id,student_id,student_name,event_type,occurred_at',
    ).in('id', eventIds),
    admin.from('watch_push_devices').select(
      'id,device_token,bundle_id,environment',
    ).in('id', deviceIds).eq('enabled', true),
  ]);
  if (eventError || deviceError) {
    return json({
      ok: false,
      error: eventError?.message ?? deviceError?.message ?? 'lookup_failed',
    }, 500);
  }
  const events = new Map(
    ((rawEvents ?? []) as EventRow[]).map((row) => [row.id, row]),
  );
  const devices = new Map(
    ((rawDevices ?? []) as DeviceRow[]).map((row) => [row.id, row]),
  );

  let sent = 0;
  let failed = 0;
  for (const delivery of deliveries) {
    const event = events.get(delivery.event_id);
    const device = devices.get(delivery.device_id);
    if (!event || !device) {
      await admin.from('watch_push_deliveries').update({
        status: 'disabled',
        last_error: 'event_or_device_missing',
        updated_at: new Date().toISOString(),
      }).eq('id', delivery.id);
      continue;
    }
    const { data: claimed } = await admin
      .from('watch_push_deliveries')
      .update({
        status: 'sending',
        attempts: delivery.attempts + 1,
        updated_at: new Date().toISOString(),
      })
      .eq('id', delivery.id)
      .in('status', ['pending', 'retry'])
      .select('id')
      .maybeSingle();
    if (!claimed) continue;

    let environment = device.environment === 'unknown'
      ? 'production'
      : device.environment;
    let result;
    try {
      result = await sendToApns(event, device, environment);
      if (!result.ok && result.reason === 'BadDeviceToken') {
        const alternate = alternateEnvironment(environment);
        const retried = await sendToApns(event, device, alternate);
        if (retried.ok) {
          result = retried;
          environment = alternate;
          await admin.from('watch_push_devices').update({
            environment,
            updated_at: new Date().toISOString(),
          }).eq('id', device.id);
        }
      }
    } catch (error) {
      result = {
        ok: false,
        status: 0,
        reason: String((error as Error)?.message ?? error),
        apnsId: '',
      };
    }

    if (result.ok) {
      sent += 1;
      await admin.from('watch_push_deliveries').update({
        status: 'sent',
        sent_at: new Date().toISOString(),
        apns_id: result.apnsId || null,
        last_error: null,
        updated_at: new Date().toISOString(),
      }).eq('id', delivery.id);
      continue;
    }

    failed += 1;
    const invalid = result.status === 410 ||
      ['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'].includes(
        result.reason,
      );
    if (invalid) {
      await Promise.all([
        admin.from('watch_push_devices').update({
          enabled: false,
          updated_at: new Date().toISOString(),
        }).eq('id', device.id),
        admin.from('watch_push_deliveries').update({
          status: 'disabled',
          last_error: `${result.status}:${result.reason}`,
          updated_at: new Date().toISOString(),
        }).eq('id', delivery.id),
      ]);
      continue;
    }
    const retryable = result.status === 0 || result.status === 429 ||
      result.status >= 500;
    const attempts = delivery.attempts + 1;
    const retry = retryable && attempts < 8;
    await admin.from('watch_push_deliveries').update({
      status: retry ? 'retry' : 'failed',
      next_attempt_at: retry
        ? new Date(Date.now() + retryDelaySeconds(attempts) * 1000).toISOString()
        : new Date().toISOString(),
      last_error: `${result.status}:${result.reason || 'unknown'}`,
      updated_at: new Date().toISOString(),
    }).eq('id', delivery.id);
  }

  return json({ ok: true, sent, failed });
});
