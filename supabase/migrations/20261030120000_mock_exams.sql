-- 20261030120000: mock exam past papers (모의고사 기출)
--
-- One exam (교육청 학력평가 / 평가원 모의평가 / 수능) holds its problem and
-- solution PDFs, one row per item with the crop on the problem page, the answer,
-- and the solution position on the solution page. Grade 3 stores the common
-- items (1~22) once and 8 items per elective; grades 1·2 have no elective.
-- See docs/architecture/mock-exam.md.

create table if not exists public.mock_exams (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  grade smallint not null check (grade between 1 and 3),
  exam_year int not null check (exam_year between 2000 and 2100),
  -- 학년도. 고3만 exam_year + 1 로 채운다. 앱 표시는 exam_year 로 한다.
  school_year int check (school_year is null or school_year between 2000 and 2101),
  exam_month smallint not null check (exam_month between 1 and 12),
  org text not null check (org in ('edu', 'kice', 'csat')),
  curriculum_code text not null default 'rev_2015',
  title text not null default '',
  status text not null default 'draft'
    check (status in ('draft', 'queued', 'running', 'review', 'failed')),
  stage text not null default '',
  progress jsonb not null default '{}'::jsonb,
  last_error text not null default '',
  locked_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (academy_id, grade, exam_year, exam_month, org)
);

create index if not exists mock_exams_status_idx
  on public.mock_exams(status, updated_at);

create table if not exists public.mock_exam_papers (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  exam_id uuid not null references public.mock_exams(id) on delete cascade,
  kind text not null check (kind in ('problem', 'solution')),
  elective text not null default ''
    check (elective in ('', 'probstats', 'calculus', 'geometry')),
  storage_bucket text not null default 'problem-documents',
  storage_path text not null,
  file_name text not null default '',
  sha256 text not null default '',
  size_bytes bigint not null default 0,
  page_count int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (exam_id, kind, elective)
);

create table if not exists public.mock_exam_items (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  exam_id uuid not null references public.mock_exams(id) on delete cascade,
  section text not null
    check (section in ('common', 'probstats', 'calculus', 'geometry')),
  problem_number int not null check (problem_number between 1 and 60),

  paper_id uuid references public.mock_exam_papers(id) on delete set null,
  raw_page int,
  item_region_1k int[],

  answer_kind text check (answer_kind is null or answer_kind in ('objective', 'subjective')),
  answer_text text not null default '',
  answer_source text not null default 'vlm' check (answer_source in ('vlm', 'manual')),
  score smallint,

  solution_paper_id uuid references public.mock_exam_papers(id) on delete set null,
  solution_raw_page int,
  solution_number_region_1k int[],
  solution_content_region_1k int[],
  solution_source text not null default 'vlm' check (solution_source in ('vlm', 'manual')),

  pb_question_id uuid references public.pb_questions(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (exam_id, section, problem_number)
);

create index if not exists mock_exam_items_exam_idx
  on public.mock_exam_items(exam_id, section, problem_number);

create table if not exists public.mock_exam_sections (
  exam_id uuid not null references public.mock_exams(id) on delete cascade,
  section text not null
    check (section in ('common', 'probstats', 'calculus', 'geometry')),
  academy_id uuid not null references public.academies(id) on delete cascade,
  pb_document_id uuid references public.pb_documents(id) on delete set null,
  extract_job_id uuid references public.pb_extract_jobs(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (exam_id, section)
);

do $$ begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    drop trigger if exists trg_mock_exams_updated_at on public.mock_exams;
    create trigger trg_mock_exams_updated_at
      before update on public.mock_exams
      for each row execute function public.set_updated_at();
    drop trigger if exists trg_mock_exam_papers_updated_at on public.mock_exam_papers;
    create trigger trg_mock_exam_papers_updated_at
      before update on public.mock_exam_papers
      for each row execute function public.set_updated_at();
    drop trigger if exists trg_mock_exam_items_updated_at on public.mock_exam_items;
    create trigger trg_mock_exam_items_updated_at
      before update on public.mock_exam_items
      for each row execute function public.set_updated_at();
    drop trigger if exists trg_mock_exam_sections_updated_at on public.mock_exam_sections;
    create trigger trg_mock_exam_sections_updated_at
      before update on public.mock_exam_sections
      for each row execute function public.set_updated_at();
  end if;
end $$;

-- RLS: academy members, the same as the textbook crop tables.
do $$
declare
  t text;
begin
  foreach t in array array['mock_exams', 'mock_exam_papers', 'mock_exam_items', 'mock_exam_sections'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || ' select', t);
    execute format(
      'create policy %I on public.%I for select using (exists (select 1 from public.memberships m where m.user_id = auth.uid() and m.academy_id = %I.academy_id))',
      t || ' select', t, t
    );
    execute format('drop policy if exists %I on public.%I', t || ' insert', t);
    execute format(
      'create policy %I on public.%I for insert with check (exists (select 1 from public.memberships m where m.user_id = auth.uid() and m.academy_id = %I.academy_id))',
      t || ' insert', t, t
    );
    execute format('drop policy if exists %I on public.%I', t || ' update', t);
    execute format(
      'create policy %I on public.%I for update using (exists (select 1 from public.memberships m where m.user_id = auth.uid() and m.academy_id = %I.academy_id)) with check (exists (select 1 from public.memberships m where m.user_id = auth.uid() and m.academy_id = %I.academy_id))',
      t || ' update', t, t, t
    );
    execute format('drop policy if exists %I on public.%I', t || ' delete', t);
    execute format(
      'create policy %I on public.%I for delete using (exists (select 1 from public.memberships m where m.user_id = auth.uid() and m.academy_id = %I.academy_id))',
      t || ' delete', t, t
    );
  end loop;
end $$;

comment on table public.mock_exams is
  '모의고사 기출 시험 한 회. grade·exam_year·exam_month·org 로 학원 안에서 하나.';
comment on table public.mock_exam_items is
  '모의고사 문항. 문제지 크롭·정답·해설 위치(0~1000 좌표, [ymin,xmin,ymax,xmax]).';

notify pgrst, 'reload schema';
