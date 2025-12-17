-- lesson_snapshots: 압축 스냅샷 헤더/디테일 + attendance_records.snapshot_id 추가

-- 헤더: 스케줄/과금 메타를 압축 저장
create table if not exists public.lesson_snapshot_headers (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  snapshot_at timestamptz not null default now(),
  effective_start date not null,
  effective_end date,
  weekly_count integer,
  day_pattern integer[],          -- 요일 패턴(0=월)
  expected_sessions integer,      -- 효력 구간 내 예상 회차
  billed_amount numeric,          -- 선택: 과금 메타
  unit_price numeric,             -- 선택: 회당 단가
  note text,
  set_ids text[],                 -- 선택: 포함된 set_id 리스트
  source text,                    -- 예: 'cycle_start', 'schedule_change'
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_lsh_academy on public.lesson_snapshot_headers(academy_id);

-- 디테일: 슬롯 단위 정보 (옵션이지만 SQL 필터/정렬을 위해 테이블로 유지)
create table if not exists public.lesson_snapshot_blocks (
  id uuid primary key default gen_random_uuid(),
  snapshot_id uuid not null references public.lesson_snapshot_headers(id) on delete cascade,
  day_index integer not null,
  start_hour integer not null,
  start_minute integer not null,
  duration integer not null,
  number integer,
  weekly_order integer,
  set_id text,
  session_type_id text
);
create index if not exists idx_lsb_snapshot on public.lesson_snapshot_blocks(snapshot_id);

-- attendance_records에 스냅샷 근거 저장
alter table public.attendance_records
  add column if not exists snapshot_id uuid references public.lesson_snapshot_headers(id);



