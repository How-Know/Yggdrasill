-- lesson_occurrences: "원본 회차(occurrence)"를 고정 저장하는 테이블
-- - 보강(replace)은 원본 occurrence의 cycle/session_order를 유지한 채 실제 수행 시간을 변경
-- - 추가수업(add)은 kind='extra' occurrence로 저장(사이클 집계에서는 제외/별도 집계)
--
-- NOTE:
-- - attendance_records.class_date_time은 UTC minute 정규화 + (academy_id, student_id, class_date_time) 유니크 제약이 이미 존재함.
-- - occurrence의 original_class_datetime도 동일하게 UTC minute 정규화하여 안정적인 조인/역추적을 보장한다.

-- 1) Table: lesson_occurrences ---------------------------------------------------
create table if not exists public.lesson_occurrences (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,

  -- regular: 사이클에 포함되는 원본 회차(고정)
  -- extra:   추가수업(사이클 집계에서 제외, 별도 집계)
  kind text not null default 'regular',

  -- 사이클 번호(보강은 원본 cycle로 귀속)
  cycle integer not null,
  -- 회차(regular만 채움). extra는 null 유지 권장.
  session_order integer,

  -- 원본 수업 시간(UTC minute 정규화)
  original_class_datetime timestamptz not null,
  original_class_end_time timestamptz,
  duration_minutes integer,

  -- 원본의 수업 타입/세트(스케줄 블록 기반)
  session_type_id text,
  set_id text,

  -- 스냅샷 근거(선택): cycle 고정 스냅샷/스케줄 변경 추적용
  snapshot_id uuid references public.lesson_snapshot_headers(id) on delete set null,

  -- OCC/audit
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_lesson_occurrences_academy
  on public.lesson_occurrences(academy_id);
create index if not exists idx_lesson_occurrences_student_cycle
  on public.lesson_occurrences(student_id, cycle, session_order);

-- 동일 학생/세트/원본분(minute)에서 중복 occurrence 방지(세트가 있을 때만)
create unique index if not exists uidx_lesson_occurrences_student_kind_set_dt
  on public.lesson_occurrences(academy_id, student_id, kind, set_id, original_class_datetime)
  where set_id is not null and set_id <> '';

alter table public.lesson_occurrences enable row level security;
drop policy if exists lesson_occurrences_all on public.lesson_occurrences;
create policy lesson_occurrences_all on public.lesson_occurrences for all
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = lesson_occurrences.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = lesson_occurrences.academy_id
      and m.user_id = auth.uid()
  )
);

-- audit trigger
drop trigger if exists trg_lesson_occurrences_audit on public.lesson_occurrences;
create trigger trg_lesson_occurrences_audit
before insert or update on public.lesson_occurrences
for each row execute function public._set_audit_fields();

-- defaults/normalization trigger: UTC minute 정규화
create or replace function public._lesson_occurrence_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.original_class_datetime is not null then
    new.original_class_datetime := (date_trunc('minute', new.original_class_datetime at time zone 'UTC') at time zone 'UTC');
  end if;
  return new;
end $$;

drop trigger if exists trg_lesson_occurrence_defaults on public.lesson_occurrences;
create trigger trg_lesson_occurrence_defaults
before insert or update on public.lesson_occurrences
for each row execute function public._lesson_occurrence_defaults();


-- 2) FK columns: attendance_records/session_overrides --------------------------------
alter table public.attendance_records
  add column if not exists occurrence_id uuid references public.lesson_occurrences(id) on delete set null;
create index if not exists idx_attendance_records_occurrence_id
  on public.attendance_records(occurrence_id);

alter table public.session_overrides
  add column if not exists occurrence_id uuid references public.lesson_occurrences(id) on delete set null;
create index if not exists idx_session_overrides_occurrence_id
  on public.session_overrides(occurrence_id);


