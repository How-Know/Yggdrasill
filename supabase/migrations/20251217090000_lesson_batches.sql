create table public.lesson_batch_headers (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  snapshot_id uuid references public.lesson_snapshot_headers(id) on delete set null,
  total_sessions integer not null,
  expected_sessions integer,
  consumed_sessions integer not null default 0,
  term_days integer,
  next_registration_date date,
  status text default 'active',
  note text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_lesson_batch_headers_academy_student
  on public.lesson_batch_headers(academy_id, student_id);

create table public.lesson_batch_sessions (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.lesson_batch_headers(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  session_no integer not null,
  planned_at timestamptz,
  state text not null default 'planned',
  replaced_with_session_id uuid references public.lesson_batch_sessions(id) on delete set null,
  attendance_id uuid references public.attendance_records(id) on delete set null,
  snapshot_id uuid references public.lesson_snapshot_headers(id) on delete set null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_lesson_batch_sessions_batch
  on public.lesson_batch_sessions(batch_id, session_no);

alter table public.attendance_records
  add column if not exists batch_session_id uuid references public.lesson_batch_sessions(id) on delete set null;


