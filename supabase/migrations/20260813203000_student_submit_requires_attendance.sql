-- 과제 제출(검사 요청)은 등원 중일 때만 받는다.
--
-- 집에서도 과제를 수행하고 채점하는 것은 그대로 허용한다. 다만 "검사해
-- 주세요"는 학원에서 눌러야 한다. 하원하면 모든 과제가 대기로 돌아가므로,
-- 집에서 더 한 뒤 다음 등원 때 제출하는 흐름이 된다.
--
-- 20260707000000_student_app_auth.sql 의 정의에 등원 검사만 더한 사본이다.

create or replace function public.student_group_transition(
  p_group_id uuid,
  p_from_phase smallint default null,
  p_request_id text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_request_id text := nullif(trim(coalesce(p_request_id, '')), '');
  v_device_id text;
  v_group_student uuid;
  v_current_phase smallint;
  v_changed integer := 0;
  v_inserted integer := 0;
  v_result jsonb;
  v_existing jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;
  if p_group_id is null then
    return jsonb_build_object('ok', false, 'error', 'group_id_required');
  end if;
  if v_request_id is null then
    return jsonb_build_object('ok', false, 'error', 'request_id_required');
  end if;
  v_device_id := 'student-app:' || auth.uid()::text;

  select g.student_id into v_group_student
  from public.homework_groups g
  where g.id = p_group_id and g.academy_id = v_academy
  limit 1;

  if v_group_student is null then
    return jsonb_build_object('ok', false, 'error', 'group_not_found');
  end if;
  if v_group_student <> v_student then
    return jsonb_build_object('ok', false, 'error', 'not_your_group');
  end if;

  -- 제출은 등원 중에만. 요청 ID 를 소모하기 전에 막는다.
  if p_from_phase = 99
     and public._student_location_kind(v_academy, v_student, now()) <> 'academy' then
    return jsonb_build_object('ok', false, 'error', 'not_at_academy');
  end if;

  -- phase 가드 (m5_group_transition_command와 동일 규칙)
  if p_from_phase is not null then
    perform public.m5_group_runtime_seed(v_academy, p_group_id);
    select r.phase into v_current_phase
      from public.homework_group_runtime r
     where r.academy_id = v_academy and r.group_id = p_group_id
     limit 1;

    if v_current_phase is not null then
      if p_from_phase in (1, 2, 4) and v_current_phase <> p_from_phase then
        return jsonb_build_object(
          'ok', false, 'error', 'phase_mismatch',
          'current_phase', v_current_phase, 'from_phase', p_from_phase
        );
      elsif p_from_phase = 99 and v_current_phase not in (1, 2) then
        return jsonb_build_object(
          'ok', false, 'error', 'phase_mismatch',
          'current_phase', v_current_phase, 'from_phase', p_from_phase
        );
      end if;
    end if;
  end if;

  insert into public.homework_group_transition_requests (
    academy_id, request_id, group_id, student_id, from_phase, device_id
  ) values (
    v_academy, v_request_id, p_group_id, v_student, p_from_phase, v_device_id
  )
  on conflict (academy_id, request_id) do nothing;

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    select r.result_json into v_existing
      from public.homework_group_transition_requests r
     where r.academy_id = v_academy and r.request_id = v_request_id
     limit 1;
    if v_existing is null then
      return jsonb_build_object('ok', true, 'dedup', true, 'changed', 0);
    end if;
    return v_existing || jsonb_build_object('dedup', true);
  end if;

  v_changed := coalesce(
    public.homework_group_bulk_transition(p_group_id, v_academy, p_from_phase),
    0
  );

  v_result := jsonb_build_object(
    'ok', true, 'dedup', false, 'changed', v_changed,
    'group_id', p_group_id, 'from_phase', p_from_phase,
    'request_id', v_request_id
  );

  update public.homework_group_transition_requests r
     set changed_count = v_changed, result_json = v_result, updated_at = now()
   where r.academy_id = v_academy and r.request_id = v_request_id;

  return v_result;
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end; $$;

revoke all on function public.student_group_transition(uuid, smallint, text) from public;
grant execute on function public.student_group_transition(uuid, smallint, text)
  to authenticated;
