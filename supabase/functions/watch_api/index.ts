// Apple Watch 단독 동작용 Edge Function.
//
// 인증: iPhone이 릴레이한 Supabase 사용자 JWT를 그대로 Authorization 헤더로 받는다.
//       createUserClient(req)가 anon key + 사용자 토큰으로 동작하므로 RLS가 적용된다.
//
// 라우팅(단일 함수, action 기반):
//   GET  /watch_api?action=today_targets&academyId=...&date=YYYY-MM-DD
//   GET  /watch_api?action=homework_list&academyId=...&studentId=...&date=YYYY-MM-DD
//   POST /watch_api  { action: 'attendance', academyId, studentId, classDateTime, attAction, ... }
//   POST /watch_api  { action: 'homework_check', academyId, studentId, assignmentId, homeworkItemId, progress }
//
// 읽기(today_targets/homework_list)는 watch_snapshots에서 iPhone이 발행한 페이로드를
// 그대로 반환한다(서버/Swift에 출결·숙제 계산 로직을 중복 구현하지 않는다).

import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient, createUserClient } from '../_shared/supabase.ts';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function ok(body: Record<string, unknown> = {}) {
  return json({ ok: true, ...body });
}

function fail(message: string, status = 200) {
  return json({ ok: false, message }, status);
}

function uuidOrNull(value: unknown): string | null {
  const text = String(value ?? '').trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(text)
    ? text
    : null;
}

function kstToday(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function parseSnapshotDate(value: unknown): number | null {
  const text = String(value ?? '').trim();
  if (!text) return null;
  // Flutter의 DateTime.toIso8601String()은 로컬 시각에 offset을 붙이지 않는다.
  const normalized = /(?:Z|[+-]\d{2}:\d{2})$/i.test(text)
    ? text
    : `${text}+09:00`;
  const millis = Date.parse(normalized);
  return Number.isFinite(millis) ? millis : null;
}

function mergeLiveAttendance(
  rawItems: unknown,
  rows: Record<string, unknown>[],
): Record<string, unknown>[] {
  if (!Array.isArray(rawItems)) return [];
  return rawItems.map((raw) => {
    const item = { ...((raw ?? {}) as Record<string, unknown>) };
    const studentId = String(item.studentId ?? '');
    const setId = String(item.setId ?? '');
    const targetTime = parseSnapshotDate(item.classDateTime);
    const candidates = rows.filter((row) =>
      String(row.student_id ?? '') === studentId
    );
    let matched = candidates.find((row) =>
      setId && String(row.set_id ?? '') === setId
    );
    if (!matched && targetTime !== null) {
      matched = candidates
        .map((row) => ({
          row,
          distance: Math.abs(
            (parseSnapshotDate(row.class_date_time) ?? Number.MAX_SAFE_INTEGER) -
              targetTime,
          ),
        }))
        .filter(({ distance }) => distance <= 60_000)
        .sort((a, b) => a.distance - b.distance)[0]?.row;
    }
    if (!matched && candidates.length === 1) matched = candidates[0];
    if (!matched) return item;

    const arrivalTime = matched.arrival_time;
    const departureTime = matched.departure_time;
    item.status = departureTime
      ? 'leaved'
      : (arrivalTime || matched.is_present ? 'attended' : 'waiting');
    if (arrivalTime) item.arrivalTime = arrivalTime;
    else delete item.arrivalTime;
    if (departureTime) item.departureTime = departureTime;
    else delete item.departureTime;
    return item;
  });
}

function buildTargetsFromAttendance(
  rows: Record<string, unknown>[],
  studentNames: Map<string, string>,
): Record<string, unknown>[] {
  const bySession = new Map<string, Record<string, unknown>>();
  for (const row of rows) {
    const studentId = String(row.student_id ?? '');
    const rowId = String(row.id ?? '');
    if (!studentId || !rowId) continue;
    const key = String(row.set_id ?? '') || `attendance:${rowId}`;
    const previous = bySession.get(key);
    const hasAttendance = Boolean(row.arrival_time || row.is_present);
    const previousHasAttendance = Boolean(
      previous?.arrival_time || previous?.is_present,
    );
    if (
      previous &&
      (previousHasAttendance && !hasAttendance ||
        (previousHasAttendance === hasAttendance &&
          String(previous.class_date_time ?? '') <=
            String(row.class_date_time ?? '')))
    ) {
      continue;
    }
    bySession.set(key, row);
  }

  return [...bySession.entries()]
    .map(([setId, row]) => {
      const studentId = String(row.student_id ?? '');
      const arrivalTime = row.arrival_time;
      const departureTime = row.departure_time;
      const item: Record<string, unknown> = {
        setId,
        studentId,
        name: studentNames.get(studentId) ?? '학생',
        classDateTime: row.class_date_time,
        classEndTime: row.class_end_time ?? row.class_date_time,
        className: row.class_name ?? '수업',
        status: departureTime
          ? 'leaved'
          : (arrivalTime || row.is_present ? 'attended' : 'waiting'),
      };
      if (row.session_type_id) item.sessionTypeId = row.session_type_id;
      if (arrivalTime) item.arrivalTime = arrivalTime;
      if (departureTime) item.departureTime = departureTime;
      return item;
    })
    .sort((a, b) =>
      String(a.classDateTime ?? '').localeCompare(String(b.classDateTime ?? ''))
    );
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.toLowerCase().startsWith('bearer ')) {
    return fail('unauthorized', 401);
  }
  const supa = createUserClient(req);

  // 인증 사용자 확인(토큰 만료/위조 차단).
  const { data: userData, error: userErr } = await supa.auth.getUser();
  if (userErr || !userData?.user) {
    return fail('invalid_token', 401);
  }

  const url = new URL(req.url);
  let action = url.searchParams.get('action') ?? '';
  let body: Record<string, unknown> = {};
  if (req.method === 'POST') {
    try {
      body = await req.json();
    } catch (_) {
      body = {};
    }
    action = String(body.action ?? action);
  }

  const academyId = String(
    body.academyId ?? url.searchParams.get('academyId') ?? '',
  ).trim();
  if (!academyId) return fail('missing_academy');

  try {
    switch (action) {
      case 'today_targets': {
        const date = String(url.searchParams.get('date') ?? kstToday());
        const { data, error } = await supa
          .from('watch_snapshots')
          .select('payload, updated_at')
          .eq('academy_id', academyId)
          .eq('kind', 'today_targets')
          .eq('scope_key', 'all')
          .eq('snapshot_date', date)
          .maybeSingle();
        if (error) return fail(error.message);
        const payload = (data?.payload ?? {}) as Record<string, unknown>;
        const snapshotItems = Array.isArray(payload.items) ? payload.items : [];
        let items = snapshotItems as Record<string, unknown>[];
        let attendanceUpdatedAt: string | null = null;
        const { data: attendance, error: attendanceError } = await supa
          .from('attendance_records')
          .select(
            'id,student_id,set_id,session_type_id,class_date_time,class_end_time,class_name,arrival_time,departure_time,is_present,is_planned,updated_at',
          )
          .eq('academy_id', academyId)
          .eq('date', date);
        if (attendanceError) return fail(attendanceError.message);
        const rows = (attendance ?? []) as Record<string, unknown>[];
        if (snapshotItems.length > 0) {
          items = mergeLiveAttendance(snapshotItems, rows);
        } else if (rows.length > 0) {
          const ids = [
            ...new Set(rows.map((row) => String(row.student_id ?? ''))),
          ].filter(Boolean);
          const { data: students, error: studentError } = await supa
            .from('students')
            .select('id,name')
            .eq('academy_id', academyId)
            .in('id', ids);
          if (studentError) return fail(studentError.message);
          const names = new Map<string, string>(
            ((students ?? []) as Record<string, unknown>[]).map((student) => [
              String(student.id ?? ''),
              String(student.name ?? '학생'),
            ]),
          );
          items = buildTargetsFromAttendance(rows, names);
        }
        if (rows.length > 0) {
          attendanceUpdatedAt = rows
            .map((row) => String(row.updated_at ?? ''))
            .filter(Boolean)
            .sort()
            .at(-1) ?? null;
        }
        return ok({
          type: 'todayTargets',
          date,
          updatedAt: data?.updated_at ?? null,
          attendanceUpdatedAt,
          items,
        });
      }

      case 'homework_list': {
        const studentId = String(url.searchParams.get('studentId') ?? '').trim();
        if (!studentId) return fail('missing_student');
        const date = String(url.searchParams.get('date') ?? kstToday());
        const { data, error } = await supa
          .from('watch_snapshots')
          .select('payload, updated_at')
          .eq('academy_id', academyId)
          .eq('kind', 'homework')
          .eq('scope_key', studentId)
          .eq('snapshot_date', date)
          .maybeSingle();
        if (error) return fail(error.message);
        const payload = (data?.payload ?? {}) as Record<string, unknown>;
        return ok({
          type: 'homeworkList',
          studentId,
          updatedAt: data?.updated_at ?? null,
          items: payload.items ?? [],
        });
      }

      case 'attendance': {
        const studentId = String(body.studentId ?? '').trim();
        const classDateTime = String(body.classDateTime ?? '').trim();
        const attAction = String(body.attAction ?? body.action2 ?? '').trim();
        if (!studentId || !classDateTime) return fail('missing_attendance_fields');
        if (attAction !== 'arrival' && attAction !== 'departure') {
          return fail('invalid_action');
        }
        const { error } = await supa.rpc('watch_record_attendance', {
          p_academy_id: academyId,
          p_student_id: studentId,
          p_class_date_time: classDateTime,
          p_action: attAction,
          p_class_end_time: body.classEndTime ? String(body.classEndTime) : null,
          p_class_name: body.className ? String(body.className) : null,
          p_set_id: uuidOrNull(body.setId),
          p_session_type_id: uuidOrNull(body.sessionTypeId),
        });
        if (error) return fail(error.message);
        return ok({
          message: attAction === 'arrival' ? '등원 기록됨' : '하원 기록됨',
        });
      }

      case 'register_push_token': {
        const deviceToken = String(body.deviceToken ?? '')
          .trim()
          .toLowerCase();
        const bundleId = String(
          body.bundleId ?? 'com.beleunu.yggdrasill.watchkitapp',
        ).trim();
        const rawEnvironment = String(body.environment ?? 'unknown');
        const environment = ['development', 'production'].includes(
            rawEnvironment,
          )
          ? rawEnvironment
          : 'unknown';
        if (!/^[0-9a-f]{32,256}$/.test(deviceToken)) {
          return fail('invalid_device_token');
        }
        if (bundleId !== 'com.beleunu.yggdrasill.watchkitapp') {
          return fail('invalid_bundle_id');
        }
        const { data: membership, error: membershipError } = await supa
          .from('memberships')
          .select('academy_id')
          .eq('academy_id', academyId)
          .eq('user_id', userData.user.id)
          .maybeSingle();
        if (membershipError || !membership) return fail('not_a_member', 403);

        const admin = createAdminClient();
        const { error } = await admin.from('watch_push_devices').upsert({
          academy_id: academyId,
          user_id: userData.user.id,
          device_token: deviceToken,
          bundle_id: bundleId,
          environment,
          enabled: true,
          app_version: body.appVersion
            ? String(body.appVersion)
            : null,
          os_version: body.osVersion ? String(body.osVersion) : null,
          last_seen_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }, { onConflict: 'device_token' });
        if (error) return fail(error.message);
        return ok({ message: 'watch_push_ready' });
      }

      case 'homework_check': {
        const studentId = String(body.studentId ?? '').trim();
        const assignmentId = String(body.assignmentId ?? '').trim();
        const homeworkItemId = String(body.homeworkItemId ?? '').trim();
        const progressRaw = Number(body.progress ?? NaN);
        if (!studentId || !assignmentId || !homeworkItemId || !Number.isFinite(progressRaw)) {
          return fail('missing_homework_fields');
        }
        const progress = Math.max(0, Math.min(150, Math.round(progressRaw)));
        const markCompleted = progress >= 100;

        const { error: checkErr } = await supa.rpc('homework_assignment_check', {
          p_assignment_id: assignmentId,
          p_academy_id: academyId,
          p_progress: progress,
          p_issue_type: null,
          p_issue_note: null,
          p_status: markCompleted ? 'completed' : null,
          p_updated_by: userData.user.id,
        });
        if (checkErr) return fail(checkErr.message);

        // phase 전환: 100% 이상이면 제출, 아니면 대기.
        const phaseRpc = markCompleted ? 'homework_submit' : 'homework_wait';
        const { error: phaseErr } = await supa.rpc(phaseRpc, {
          p_item_id: homeworkItemId,
          p_academy_id: academyId,
          p_updated_by: userData.user.id,
        });
        if (phaseErr) {
          // phase 전환 실패는 치명적이지 않음(검사는 이미 기록됨). 로그만 남긴다.
          console.warn('[watch_api] phase rpc failed', phaseErr.message);
        }

        if (!markCompleted) {
          // 학습앱의 clearActiveAssignmentsForItems와 동일하게 활성 배정을 이월 처리.
          await supa
            .from('homework_assignments')
            .update({ status: 'carried_over' })
            .eq('academy_id', academyId)
            .eq('student_id', studentId)
            .eq('homework_item_id', homeworkItemId)
            .eq('status', 'assigned');
        }

        return ok({ message: `숙제 ${progress}% 기록됨` });
      }

      default:
        return fail('unknown_action');
    }
  } catch (e) {
    console.error('[watch_api] error', e);
    return fail(`server_error: ${String((e as Error)?.message ?? e)}`);
  }
});
