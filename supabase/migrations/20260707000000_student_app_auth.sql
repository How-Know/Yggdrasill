-- 학생용 앱(iPad) 인증/API 기반.
--
-- 구조:
--   * 학생은 Supabase Auth 이메일/비밀번호 계정을 사용한다.
--     (아이디를 학생이 정하고, 앱이 내부적으로 <아이디>@student.yggdrasill.app 로 변환)
--   * 가입은 원장이 학습앱에서 발급한 1회용 가입코드로만 가능하다.
--     (실제 계정 생성은 student_signup Edge Function이 service role로 수행)
--   * 로그인 후에는 student_app_accounts 로 auth.uid() ↔ (academy, student)를
--     매핑하고, student_* RPC(모두 security definer + 본인 검증)로만 접근한다.
--   * M5 RPC들은 기기 바인딩(m5_device_bindings) 전제라 재사용하되,
--     바인딩 검증 대신 계정 매핑 검증으로 대체한 student_* 래퍼를 둔다.

-- ---------------------------------------------------------------------------
-- 1) 계정 매핑
-- ---------------------------------------------------------------------------
create table if not exists public.student_app_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  username text not null,
  created_at timestamptz not null default now(),
  constraint uq_student_app_accounts_student unique (student_id)
);

alter table public.student_app_accounts enable row level security;

drop policy if exists student_app_accounts_select_self on public.student_app_accounts;
create policy student_app_accounts_select_self on public.student_app_accounts
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.memberships m
      where m.academy_id = student_app_accounts.academy_id
        and m.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 가입코드
-- ---------------------------------------------------------------------------
create table if not exists public.student_signup_codes (
  code text primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  created_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  used_at timestamptz null,
  used_by uuid null references auth.users(id) on delete set null
);

create index if not exists idx_student_signup_codes_student
  on public.student_signup_codes (academy_id, student_id);

alter table public.student_signup_codes enable row level security;

drop policy if exists student_signup_codes_staff_select on public.student_signup_codes;
create policy student_signup_codes_staff_select on public.student_signup_codes
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.academy_id = student_signup_codes.academy_id
        and m.user_id = auth.uid()
    )
  );

-- 원장/스태프가 학생별 가입코드를 발급한다. (기존 미사용 코드는 무효화)
create or replace function public.student_issue_signup_code(
  p_student_id uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy_id uuid;
  v_code text;
begin
  select s.academy_id into v_academy_id
  from public.students s
  where s.id = p_student_id;

  if v_academy_id is null then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy_id and m.user_id = auth.uid()
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_a_member');
  end if;

  -- 이미 계정이 연결된 학생이면 발급 불가
  if exists (
    select 1 from public.student_app_accounts a where a.student_id = p_student_id
  ) then
    return jsonb_build_object('ok', false, 'error', 'already_registered');
  end if;

  -- 기존 미사용 코드 무효화
  update public.student_signup_codes
     set expires_at = now()
   where student_id = p_student_id
     and used_at is null
     and expires_at > now();

  -- 헷갈리는 문자(0/O/1/I) 제외 8자리
  select string_agg(
           substr('23456789ABCDEFGHJKMNPQRSTUVWXYZ',
                  (floor(random() * 31) + 1)::int, 1),
           ''
         )
    into v_code
    from generate_series(1, 8);

  insert into public.student_signup_codes (code, academy_id, student_id, created_by)
  values (v_code, v_academy_id, p_student_id, auth.uid());

  return jsonb_build_object('ok', true, 'code', v_code);
end; $$;

revoke all on function public.student_issue_signup_code(uuid) from public;
grant execute on function public.student_issue_signup_code(uuid) to authenticated;

-- 가입코드 사용 처리 + 계정 매핑 생성 (Edge Function 전용, service role).
create or replace function public.student_signup_redeem(
  p_code text,
  p_user_id uuid,
  p_username text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row public.student_signup_codes%rowtype;
begin
  select * into v_row
  from public.student_signup_codes
  where code = upper(trim(p_code))
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'code_not_found');
  end if;
  if v_row.used_at is not null then
    return jsonb_build_object('ok', false, 'error', 'code_used');
  end if;
  if v_row.expires_at <= now() then
    return jsonb_build_object('ok', false, 'error', 'code_expired');
  end if;
  if exists (
    select 1 from public.student_app_accounts a where a.student_id = v_row.student_id
  ) then
    return jsonb_build_object('ok', false, 'error', 'already_registered');
  end if;

  insert into public.student_app_accounts (user_id, academy_id, student_id, username)
  values (p_user_id, v_row.academy_id, v_row.student_id, p_username);

  update public.student_signup_codes
     set used_at = now(), used_by = p_user_id
   where code = v_row.code;

  return jsonb_build_object(
    'ok', true,
    'academy_id', v_row.academy_id,
    'student_id', v_row.student_id
  );
end; $$;

revoke all on function public.student_signup_redeem(text, uuid, text) from public;
grant execute on function public.student_signup_redeem(text, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3) 본인 식별 헬퍼
-- ---------------------------------------------------------------------------
create or replace function public.student_app_identity()
returns table(academy_id uuid, student_id uuid)
language sql security definer set search_path = public as $$
  select a.academy_id, a.student_id
  from public.student_app_accounts a
  where a.user_id = auth.uid()
  limit 1;
$$;

revoke all on function public.student_app_identity() from public;
grant execute on function public.student_app_identity() to authenticated;

-- ---------------------------------------------------------------------------
-- 4) 학생용 RPC 래퍼 (모두 본인 계정 검증 후 기존 M5 로직 재사용)
-- ---------------------------------------------------------------------------

-- 내 정보
create or replace function public.student_get_info()
returns table(
  name text, school text, education_level integer, grade integer,
  start_hour integer, start_minute integer, duration integer
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  return query select * from public.m5_get_student_info(v_academy, v_student);
end; $$;

revoke all on function public.student_get_info() from public;
grant execute on function public.student_get_info() to authenticated;

-- 과제 그룹 목록 (M5와 동일 형태)
create or replace function public.student_list_homework_groups_v1()
returns table(
  group_id uuid, group_title text, order_index integer, phase smallint,
  accumulated bigint, cycle_elapsed bigint, check_count integer,
  total_count integer, color bigint, page_summary text,
  run_start timestamptz, first_started_at timestamptz, content text,
  book_id text, grade_label text, "type" text, time_limit_minutes integer,
  m5_wait_title text, children jsonb
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  return query select * from public.m5_list_homework_groups(v_academy, v_student);
end; $$;

revoke all on function public.student_list_homework_groups_v1() from public;
grant execute on function public.student_list_homework_groups_v1() to authenticated;

-- 하원 숙제 그룹 목록
create or replace function public.student_list_homework_only_groups_v1()
returns table(
  group_id uuid, group_title text, order_index integer, phase smallint,
  accumulated bigint, cycle_elapsed bigint, check_count integer,
  total_count integer, color bigint, page_summary text,
  run_start timestamptz, first_started_at timestamptz, content text,
  book_id text, grade_label text, "type" text, time_limit_minutes integer,
  m5_wait_title text, children jsonb
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  return query select * from public.m5_list_homework_only_groups(v_academy, v_student);
end; $$;

revoke all on function public.student_list_homework_only_groups_v1() from public;
grant execute on function public.student_list_homework_only_groups_v1() to authenticated;

-- 테스트/내신 플래그
create or replace function public.student_group_test_naesin_flags()
returns table(group_id uuid, is_test boolean, is_naesin boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  return query select * from public.m5_group_test_naesin_flags(v_academy, v_student);
end; $$;

revoke all on function public.student_group_test_naesin_flags() from public;
grant execute on function public.student_group_test_naesin_flags() to authenticated;

-- 완료 예약 플래그
create or replace function public.student_group_pending_complete_flags()
returns table(group_id uuid, pending_complete boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  return query select * from public.m5_group_pending_complete_flags(v_academy, v_student);
end; $$;

revoke all on function public.student_group_pending_complete_flags() from public;
grant execute on function public.student_group_pending_complete_flags() to authenticated;

-- 그룹 전환 (m5_group_transition_command와 동일 로직, 기기 바인딩 대신 계정 검증)
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
grant execute on function public.student_group_transition(uuid, smallint, text) to authenticated;

-- 전체 일시정지
create or replace function public.student_pause_all()
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  perform public.homework_pause_all(v_student, v_academy, 'student-app:' || auth.uid()::text);
end; $$;

revoke all on function public.student_pause_all() from public;
grant execute on function public.student_pause_all() to authenticated;

-- 질문 요청 (선생님 호출)
create or replace function public.student_raise_question()
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid; v_name text; v_id uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.name into v_name
  from public.students s
  where s.id = v_student and s.academy_id = v_academy
  limit 1;

  insert into public.m5_student_question_requests (
    academy_id, student_id, device_id, student_display_name
  ) values (
    v_academy, v_student,
    'student-app:' || auth.uid()::text,
    coalesce(nullif(trim(v_name), ''), '')
  )
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.student_raise_question() from public;
grant execute on function public.student_raise_question() to authenticated;

-- 서술형 쓰기 과제 추가 (m5_create_descriptive_writing_group 동일 로직)
create or replace function public.student_create_descriptive_writing()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_group_id uuid; v_item_id uuid;
  v_next_group_ord integer; v_next_item_ord integer;
  v_flow_id uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select sf.id into v_flow_id
  from public.student_flows sf
  where sf.academy_id = v_academy
    and sf.student_id = v_student
    and sf.name = '서술'
  order by sf.order_index nulls last, sf.created_at asc
  limit 1;

  select coalesce(max(g.order_index), -1) + 1 into v_next_group_ord
  from public.homework_groups g
  where g.academy_id = v_academy
    and g.student_id = v_student
    and g.status = 'active';

  select coalesce(max(h.order_index), -1) + 1 into v_next_item_ord
  from public.homework_items h
  where h.academy_id = v_academy
    and h.student_id = v_student;

  insert into public.homework_groups (
    academy_id, student_id, title, order_index, status, flow_id
  ) values (
    v_academy, v_student, '서술형 쓰기', v_next_group_ord, 'active', v_flow_id
  )
  returning id into v_group_id;

  insert into public.homework_items (
    academy_id, student_id, title, type, memo, phase, order_index,
    accumulated_ms, check_count, default_split_parts, flow_id
  ) values (
    v_academy, v_student, '서술형 쓰기', '학습', '두 문제 이상 쓰기', 1,
    v_next_item_ord, 0, 0, 1, v_flow_id
  )
  returning id into v_item_id;

  insert into public.homework_group_items (
    academy_id, group_id, homework_item_id, student_id, item_order_index
  ) values (
    v_academy, v_group_id, v_item_id, v_student, 0
  );

  perform public.homework_start(v_item_id, v_student, v_academy, v_student::text);

  return jsonb_build_object(
    'group_id', v_group_id, 'item_id', v_item_id, 'student_id', v_student
  );
end; $$;

revoke all on function public.student_create_descriptive_writing() from public;
grant execute on function public.student_create_descriptive_writing() to authenticated;

-- 등원/하원 기록
create or replace function public.student_record_arrival()
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  perform public.m5_record_arrival(v_academy, v_student);
end; $$;

revoke all on function public.student_record_arrival() from public;
grant execute on function public.student_record_arrival() to authenticated;

create or replace function public.student_record_departure()
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  perform public.m5_record_departure(v_academy, v_student);
end; $$;

revoke all on function public.student_record_departure() from public;
grant execute on function public.student_record_departure() to authenticated;

-- 오늘 출결 상태 (등원/하원 시간)
create or replace function public.student_today_attendance()
returns table(arrival_time timestamptz, departure_time timestamptz, class_date_time timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  today_date date := (now() at time zone 'Asia/Seoul')::date;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  return query
  select ar.arrival_time, ar.departure_time, ar.class_date_time
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.date = today_date
  order by ar.class_date_time asc nulls last;
end; $$;

revoke all on function public.student_today_attendance() from public;
grant execute on function public.student_today_attendance() to authenticated;
