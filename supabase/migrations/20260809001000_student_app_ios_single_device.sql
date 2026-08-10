-- 아이패드(학생앱 iOS) 1인 1기기: 마지막에 로그인한 iPad install_id 만 유효.
-- Windows 등 비-iOS 는 install_id 없이 하트비트 → 기기 제한 없음.

alter table public.student_app_accounts
  add column if not exists active_ios_install_id text;

alter table public.student_app_accounts
  add column if not exists active_ios_claimed_at timestamptz;

comment on column public.student_app_accounts.active_ios_install_id is
  '마지막에 클레임한 학생앱 iOS 설치 ID. 다른 iPad 가 클레임하면 교체된다.';

-- 하트비트: optional p_ios_install_id
--   · null  → 비-iOS (제한 없음)
--   · 값    → 계정 active_ios_install_id 와 다르면 device_replaced
drop function if exists public.student_app_heartbeat();
drop function if exists public.student_app_heartbeat(text);

create or replace function public.student_app_heartbeat(
  p_ios_install_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Seoul')::date;
  v_at_academy boolean := false;
  v_kind text;
  v_install text := nullif(trim(coalesce(p_ios_install_id, '')), '');
  v_active text;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  if v_install is not null then
    select a.active_ios_install_id into v_active
    from public.student_app_accounts a
    where a.student_id = v_student
      and a.user_id = v_user;

    if v_active is not null and v_active <> v_install then
      -- 다른 iPad 가 이미 클레임함 → 이 기기는 로그아웃해야 함
      update public.student_app_presence
      set is_online = false,
          updated_at = now(),
          last_seen = now()
      where student_id = v_student
        and is_online = true;

      return jsonb_build_object(
        'ok', false,
        'error', 'ios_device_replaced'
      );
    end if;
  end if;

  select exists (
    select 1
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.date = v_day
      and ar.arrival_time is not null
      and ar.departure_time is null
  ) into v_at_academy;

  v_kind := case when v_at_academy then 'academy' else 'home' end;

  insert into public.student_app_presence as p (
    student_id, academy_id, user_id, is_online, last_seen, location_kind, updated_at
  ) values (
    v_student, v_academy, v_user, true, now(), v_kind, now()
  )
  on conflict (student_id) do update set
    academy_id = excluded.academy_id,
    user_id = excluded.user_id,
    is_online = true,
    last_seen = excluded.last_seen,
    location_kind = excluded.location_kind,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'location_kind', v_kind,
    'last_seen', now()
  );
end;
$$;

revoke all on function public.student_app_heartbeat(text) from public;
grant execute on function public.student_app_heartbeat(text) to authenticated;

-- iOS 로그인/홈 진입 시 이 설치를 활성 기기로 클레임 (다른 iPad 를 밀어냄).
create or replace function public.student_app_claim_ios_device(
  p_ios_install_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_user uuid := auth.uid();
  v_install text := nullif(trim(coalesce(p_ios_install_id, '')), '');
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;
  if v_install is null then
    raise exception 'install_id required';
  end if;

  select i.student_id into v_student from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  update public.student_app_accounts
  set active_ios_install_id = v_install,
      active_ios_claimed_at = now()
  where student_id = v_student
    and user_id = v_user;

  if not found then
    raise exception 'no student account';
  end if;

  return jsonb_build_object('ok', true, 'ios_install_id', v_install);
end;
$$;

revoke all on function public.student_app_claim_ios_device(text) from public;
grant execute on function public.student_app_claim_ios_device(text) to authenticated;
