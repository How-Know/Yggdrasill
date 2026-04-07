-- M5 "질문" 버튼 → 학원 앱 홈에서 칩으로 표시·확인(ack)

create table if not exists public.m5_student_question_requests (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  device_id text not null,
  student_display_name text not null default '',
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz null,
  acknowledged_by uuid null references auth.users(id) on delete set null
);

create index if not exists idx_m5_sqr_academy_created
  on public.m5_student_question_requests (academy_id, created_at desc);

create index if not exists idx_m5_sqr_academy_pending
  on public.m5_student_question_requests (academy_id)
  where acknowledged_at is null;

alter table public.m5_student_question_requests enable row level security;

drop policy if exists m5_sqr_select on public.m5_student_question_requests;
create policy m5_sqr_select on public.m5_student_question_requests
  for select to authenticated
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = m5_student_question_requests.academy_id
        and m.user_id = auth.uid()
    )
  );

-- 게이트웨이(서비스 롤) 전용: 바인딩 검증 후 insert
create or replace function public.m5_raise_student_question(
  p_academy_id uuid,
  p_device_id text,
  p_student_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bind_student uuid;
  v_name text;
  v_id uuid;
begin
  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'device_id required';
  end if;

  select b.student_id into v_bind_student
  from public.m5_device_bindings b
  where b.academy_id = p_academy_id
    and b.device_id = p_device_id
    and b.active = true
  limit 1;

  if v_bind_student is null then
    raise exception 'no active binding for device';
  end if;

  if p_student_id is not null and p_student_id <> v_bind_student then
    raise exception 'student mismatch';
  end if;

  select s.name into v_name
  from public.students s
  where s.id = v_bind_student
    and s.academy_id = p_academy_id
  limit 1;

  insert into public.m5_student_question_requests (
    academy_id, student_id, device_id, student_display_name
  ) values (
    p_academy_id,
    v_bind_student,
    p_device_id,
    coalesce(nullif(trim(v_name), ''), '')
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.m5_raise_student_question(uuid, text, uuid) from public;
grant execute on function public.m5_raise_student_question(uuid, text, uuid) to service_role;

-- Flutter: 칩 탭 시 확인 처리
create or replace function public.m5_ack_student_question_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.m5_student_question_requests q
  set
    acknowledged_at = now(),
    acknowledged_by = auth.uid()
  where q.id = p_request_id
    and q.acknowledged_at is null
    and exists (
      select 1
      from public.memberships m
      where m.academy_id = q.academy_id
        and m.user_id = auth.uid()
    );
end;
$$;

revoke all on function public.m5_ack_student_question_request(uuid) from public;
grant execute on function public.m5_ack_student_question_request(uuid) to authenticated;

-- Realtime (INSERT/UPDATE for chips)
do $$
begin
  perform 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'm5_student_question_requests';
  if not found then
    execute 'alter publication supabase_realtime add table public.m5_student_question_requests';
  end if;
exception when undefined_object then null;
end $$;

alter table public.m5_student_question_requests replica identity full;
