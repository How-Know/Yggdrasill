-- 하원 확정 시점의 알림장 의미 데이터를 보존한다.
-- PDF 파일은 저장하지 않고, 이후 디자인으로 다시 렌더링할 수 있는 payload만 고정한다.

create table if not exists public.student_class_session_todo_sheet_snapshots (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  attendance_id uuid not null
    references public.attendance_records(id) on delete cascade,
  session_date date not null,
  class_name text not null default '',
  schema_version integer not null default 1,
  render_version text not null default 'refined_v1',
  payload jsonb not null,
  finalized_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint uq_todo_sheet_snapshot_attendance unique (attendance_id),
  constraint todo_sheet_snapshot_payload_object_chk
    check (jsonb_typeof(payload) = 'object'),
  constraint todo_sheet_snapshot_schema_version_chk
    check (schema_version > 0)
);

create index if not exists idx_todo_sheet_snapshots_student_date
  on public.student_class_session_todo_sheet_snapshots (
    academy_id, student_id, session_date desc, finalized_at desc
  );

create index if not exists idx_todo_sheet_snapshots_student
  on public.student_class_session_todo_sheet_snapshots (student_id);

alter table public.student_class_session_todo_sheet_snapshots
  enable row level security;

drop policy if exists todo_sheet_snapshots_staff_select
  on public.student_class_session_todo_sheet_snapshots;
create policy todo_sheet_snapshots_staff_select
on public.student_class_session_todo_sheet_snapshots
for select
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id =
        student_class_session_todo_sheet_snapshots.academy_id
      and m.user_id = auth.uid()
  )
);

create or replace function public.staff_finalize_todo_sheet_snapshot_v1(
  p_attendance_id uuid,
  p_payload jsonb,
  p_schema_version integer default 1,
  p_render_version text default 'refined_v1'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_snapshot_id uuid;
begin
  select *
    into v_attendance
    from public.attendance_records ar
   where ar.id = p_attendance_id;

  if not found then
    raise exception 'ATTENDANCE_NOT_FOUND';
  end if;

  if not exists (
    select 1
      from public.memberships m
     where m.academy_id = v_attendance.academy_id
       and m.user_id = auth.uid()
  ) then
    raise exception 'FORBIDDEN';
  end if;

  if v_attendance.departure_time is null then
    raise exception 'TODO_SHEET_SNAPSHOT_REQUIRES_DEPARTURE';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'TODO_SHEET_PAYLOAD_MUST_BE_OBJECT';
  end if;

  if coalesce(p_schema_version, 0) <= 0 then
    raise exception 'TODO_SHEET_SCHEMA_VERSION_INVALID';
  end if;

  insert into public.student_class_session_todo_sheet_snapshots (
    academy_id,
    student_id,
    attendance_id,
    session_date,
    class_name,
    schema_version,
    render_version,
    payload
  ) values (
    v_attendance.academy_id,
    v_attendance.student_id,
    v_attendance.id,
    (v_attendance.class_date_time at time zone 'Asia/Seoul')::date,
    coalesce(p_payload->>'class_name', ''),
    p_schema_version,
    coalesce(nullif(btrim(p_render_version), ''), 'refined_v1'),
    p_payload
  )
  on conflict (attendance_id) do nothing
  returning id into v_snapshot_id;

  if v_snapshot_id is null then
    select s.id
      into v_snapshot_id
      from public.student_class_session_todo_sheet_snapshots s
     where s.attendance_id = v_attendance.id;
  end if;

  return v_snapshot_id;
end;
$$;

revoke all on function public.staff_finalize_todo_sheet_snapshot_v1(
  uuid, jsonb, integer, text
) from public, anon;
grant execute on function public.staff_finalize_todo_sheet_snapshot_v1(
  uuid, jsonb, integer, text
) to authenticated;

comment on table public.student_class_session_todo_sheet_snapshots is
  '하원 확정 시점의 알림장 의미 데이터. 회차당 한 행이며 최초 확정 뒤 불변이다.';
comment on column public.student_class_session_todo_sheet_snapshots.payload is
  'PDF가 아닌 버전 있는 알림장 렌더링 payload. 로고 바이너리는 포함하지 않는다.';
