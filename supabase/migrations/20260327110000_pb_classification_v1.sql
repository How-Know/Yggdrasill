-- pb_documents / pb_questions 분류 체계 v1
-- 교육과정 + 출처 + 학교/교재 메타를 정규 컬럼으로 저장한다.

alter table public.pb_documents
  add column if not exists curriculum_code text not null default 'rev_2022',
  add column if not exists source_type_code text not null default 'school_past',
  add column if not exists course_label text not null default '',
  add column if not exists grade_label text not null default '',
  add column if not exists exam_year integer,
  add column if not exists semester_label text not null default '',
  add column if not exists exam_term_label text not null default '',
  add column if not exists school_name text not null default '',
  add column if not exists publisher_name text not null default '',
  add column if not exists material_name text not null default '',
  add column if not exists classification_detail jsonb not null default '{}'::jsonb;

alter table public.pb_questions
  add column if not exists curriculum_code text not null default 'rev_2022',
  add column if not exists source_type_code text not null default 'school_past',
  add column if not exists course_label text not null default '',
  add column if not exists grade_label text not null default '',
  add column if not exists exam_year integer,
  add column if not exists semester_label text not null default '',
  add column if not exists exam_term_label text not null default '',
  add column if not exists school_name text not null default '',
  add column if not exists publisher_name text not null default '',
  add column if not exists material_name text not null default '',
  add column if not exists classification_detail jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pb_documents_curriculum_code_chk'
  ) then
    alter table public.pb_documents
      add constraint pb_documents_curriculum_code_chk
      check (
        curriculum_code in (
          'legacy_1to6',
          'k7_1997',
          'k7_2007',
          'rev_2009',
          'rev_2015',
          'rev_2022'
        )
      );
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'pb_documents_source_type_code_chk'
  ) then
    alter table public.pb_documents
      add constraint pb_documents_source_type_code_chk
      check (
        source_type_code in (
          'market_book',
          'lecture_book',
          'ebs_book',
          'school_past',
          'mock_past',
          'original_item'
        )
      );
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'pb_documents_semester_label_chk'
  ) then
    alter table public.pb_documents
      add constraint pb_documents_semester_label_chk
      check (semester_label in ('', '1학기', '2학기'));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'pb_documents_exam_term_label_chk'
  ) then
    alter table public.pb_documents
      add constraint pb_documents_exam_term_label_chk
      check (exam_term_label in ('', '중간', '기말'));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pb_questions_curriculum_code_chk'
  ) then
    alter table public.pb_questions
      add constraint pb_questions_curriculum_code_chk
      check (
        curriculum_code in (
          'legacy_1to6',
          'k7_1997',
          'k7_2007',
          'rev_2009',
          'rev_2015',
          'rev_2022'
        )
      );
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'pb_questions_source_type_code_chk'
  ) then
    alter table public.pb_questions
      add constraint pb_questions_source_type_code_chk
      check (
        source_type_code in (
          'market_book',
          'lecture_book',
          'ebs_book',
          'school_past',
          'mock_past',
          'original_item'
        )
      );
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'pb_questions_semester_label_chk'
  ) then
    alter table public.pb_questions
      add constraint pb_questions_semester_label_chk
      check (semester_label in ('', '1학기', '2학기'));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'pb_questions_exam_term_label_chk'
  ) then
    alter table public.pb_questions
      add constraint pb_questions_exam_term_label_chk
      check (exam_term_label in ('', '중간', '기말'));
  end if;
end $$;

-- 기존 source_classification(meta)에서 문서 분류를 백필한다.
update public.pb_documents
set
  source_type_code = case
    when lower(coalesce(meta -> 'source_classification' ->> 'private_material', 'false')) = 'true'
      then 'market_book'
    when lower(coalesce(meta -> 'source_classification' ->> 'mock_past_exam', 'false')) = 'true'
      then 'mock_past'
    when lower(coalesce(meta -> 'source_classification' ->> 'school_past_exam', 'false')) = 'true'
      then 'school_past'
    else source_type_code
  end,
  exam_year = coalesce(
    nullif(
      regexp_replace(
        coalesce(meta -> 'source_classification' -> 'naesin' ->> 'year', ''),
        '[^0-9]',
        '',
        'g'
      ),
      ''
    )::integer,
    exam_year
  ),
  school_name = coalesce(
    nullif(trim(coalesce(meta -> 'source_classification' -> 'naesin' ->> 'school_name', '')), ''),
    school_name
  ),
  grade_label = coalesce(
    nullif(trim(coalesce(meta -> 'source_classification' -> 'naesin' ->> 'grade', '')), ''),
    grade_label
  ),
  semester_label = case
    when trim(coalesce(meta -> 'source_classification' -> 'naesin' ->> 'semester', '')) in ('1학기', '2학기')
      then trim(coalesce(meta -> 'source_classification' -> 'naesin' ->> 'semester', ''))
    else semester_label
  end,
  exam_term_label = case
    when trim(coalesce(meta -> 'source_classification' -> 'naesin' ->> 'exam_term', '')) in ('중간', '기말')
      then trim(coalesce(meta -> 'source_classification' -> 'naesin' ->> 'exam_term', ''))
    else exam_term_label
  end,
  classification_detail = case
    when meta ? 'source_classification'
      then classification_detail || jsonb_build_object(
        'legacy_source_classification',
        meta -> 'source_classification'
      )
    else classification_detail
  end;

-- 문항은 문서 분류 스냅샷으로 동기화한다.
update public.pb_questions q
set
  curriculum_code = d.curriculum_code,
  source_type_code = d.source_type_code,
  course_label = d.course_label,
  grade_label = d.grade_label,
  exam_year = d.exam_year,
  semester_label = d.semester_label,
  exam_term_label = d.exam_term_label,
  school_name = d.school_name,
  publisher_name = d.publisher_name,
  material_name = d.material_name,
  classification_detail = coalesce(q.classification_detail, '{}'::jsonb) || jsonb_build_object(
    'synced_from_document',
    true
  )
from public.pb_documents d
where q.document_id = d.id;

create index if not exists idx_pb_documents_classification_filter
  on public.pb_documents (
    academy_id,
    curriculum_code,
    source_type_code,
    grade_label,
    exam_year desc,
    created_at desc
  );

create index if not exists idx_pb_questions_classification_filter
  on public.pb_questions (
    academy_id,
    curriculum_code,
    source_type_code,
    grade_label,
    exam_year desc,
    created_at desc
  );

create index if not exists idx_pb_documents_school_past_filter
  on public.pb_documents (
    academy_id,
    school_name,
    exam_year desc,
    semester_label,
    exam_term_label
  )
  where source_type_code = 'school_past';

create index if not exists idx_pb_questions_school_past_filter
  on public.pb_questions (
    academy_id,
    school_name,
    exam_year desc,
    semester_label,
    exam_term_label
  )
  where source_type_code = 'school_past';

create index if not exists idx_pb_documents_private_material_filter
  on public.pb_documents (
    academy_id,
    publisher_name,
    material_name,
    grade_label,
    created_at desc
  )
  where source_type_code in ('market_book', 'lecture_book', 'ebs_book');

create index if not exists idx_pb_questions_private_material_filter
  on public.pb_questions (
    academy_id,
    publisher_name,
    material_name,
    grade_label,
    created_at desc
  )
  where source_type_code in ('market_book', 'lecture_book', 'ebs_book');
