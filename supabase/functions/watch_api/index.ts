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
import { createUserClient } from '../_shared/supabase.ts';

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

function kstToday(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
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
        return ok({
          type: 'todayTargets',
          date,
          updatedAt: data?.updated_at ?? null,
          items: payload.items ?? [],
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
          p_set_id: body.setId ? String(body.setId) : null,
          p_session_type_id: body.sessionTypeId ? String(body.sessionTypeId) : null,
        });
        if (error) return fail(error.message);
        return ok({
          message: attAction === 'arrival' ? '등원 기록됨' : '하원 기록됨',
        });
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
