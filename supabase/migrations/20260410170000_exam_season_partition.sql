-- Exam data partitioned by season_id; active pointer on academy_settings.
-- PK becomes (academy_id, school, level, grade, date, season_id).

-- 1) Academy-wide active season (separate from academy_settings.version OCC column)
alter table public.academy_settings
  add column if not exists active_exam_season_id integer not null default 1;

comment on column public.academy_settings.active_exam_season_id is
  'Current exam schedule season; exam_* rows with matching season_id are "active".';

-- 2) exam_days
alter table public.exam_days
  add column if not exists season_id integer not null default 1;

alter table public.exam_days drop constraint if exists exam_days_pkey;
alter table public.exam_days
  add primary key (academy_id, school, level, grade, date, season_id);

create index if not exists exam_days_academy_season_idx
  on public.exam_days (academy_id, season_id);

-- 3) exam_schedules
alter table public.exam_schedules
  add column if not exists season_id integer not null default 1;

alter table public.exam_schedules drop constraint if exists exam_schedules_pkey;
alter table public.exam_schedules
  add primary key (academy_id, school, level, grade, date, season_id);

create index if not exists exam_schedules_academy_season_idx
  on public.exam_schedules (academy_id, season_id);

-- 4) exam_ranges
alter table public.exam_ranges
  add column if not exists season_id integer not null default 1;

alter table public.exam_ranges drop constraint if exists exam_ranges_pkey;
alter table public.exam_ranges
  add primary key (academy_id, school, level, grade, date, season_id);

create index if not exists exam_ranges_academy_season_idx
  on public.exam_ranges (academy_id, season_id);
