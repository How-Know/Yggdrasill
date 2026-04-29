-- Link textbook migration/course labels to the same canonical course keys used
-- by the learning app (M1-1, H-calc1, H-geometry, ...).

create or replace function public._textbook_course_info(raw_label text)
returns jsonb
language sql
immutable
as $$
  with norm as (
    select replace(
      replace(
        replace(
          replace(regexp_replace(coalesce(raw_label, ''), '[[:space:]]+', '', 'g'), '중등', ''),
          '고등',
          ''
        ),
        '과정',
        ''
      ),
      '학년',
      ''
    ) as label
  )
  select case
    when label in ('1-1', '중1-1') then
      jsonb_build_object('grade_key', 'M1', 'course_key', 'M1-1', 'course_label', '1-1')
    when label in ('1-2', '중1-2') then
      jsonb_build_object('grade_key', 'M1', 'course_key', 'M1-2', 'course_label', '1-2')
    when label in ('2-1', '중2-1') then
      jsonb_build_object('grade_key', 'M2', 'course_key', 'M2-1', 'course_label', '2-1')
    when label in ('2-2', '중2-2') then
      jsonb_build_object('grade_key', 'M2', 'course_key', 'M2-2', 'course_label', '2-2')
    when label in ('3-1', '중3-1') then
      jsonb_build_object('grade_key', 'M3', 'course_key', 'M3-1', 'course_label', '3-1')
    when label in ('3-2', '중3-2') then
      jsonb_build_object('grade_key', 'M3', 'course_key', 'M3-2', 'course_label', '3-2')
    when label in ('공통수학1', '고1공통수학1') then
      jsonb_build_object('grade_key', 'H1', 'course_key', 'H1-c1', 'course_label', '공통수학1')
    when label in ('공통수학2', '고1공통수학2') then
      jsonb_build_object('grade_key', 'H1', 'course_key', 'H1-c2', 'course_label', '공통수학2')
    when label in ('대수', '고2대수', '고3대수') then
      jsonb_build_object('grade_key', 'H2', 'course_key', 'H-algebra', 'course_label', '대수')
    when label in ('미적분1', '고2미적분1', '고3미적분1') then
      jsonb_build_object('grade_key', 'H2', 'course_key', 'H-calc1', 'course_label', '미적분1')
    when label in ('확률과통계', '확통', '고2확률과통계', '고3확률과통계') then
      jsonb_build_object('grade_key', 'H2', 'course_key', 'H-probstats', 'course_label', '확률과 통계')
    when label in ('미적분2', '고2미적분2', '고3미적분2') then
      jsonb_build_object('grade_key', 'H2', 'course_key', 'H-calc2', 'course_label', '미적분2')
    when label in ('기하', '고2기하', '고3기하') then
      jsonb_build_object('grade_key', 'H2', 'course_key', 'H-geometry', 'course_label', '기하')
    when label = '중1' then
      jsonb_build_object('grade_key', 'M1', 'course_key', '', 'course_label', coalesce(nullif(trim(raw_label), ''), '중1'))
    when label = '중2' then
      jsonb_build_object('grade_key', 'M2', 'course_key', '', 'course_label', coalesce(nullif(trim(raw_label), ''), '중2'))
    when label = '중3' then
      jsonb_build_object('grade_key', 'M3', 'course_key', '', 'course_label', coalesce(nullif(trim(raw_label), ''), '중3'))
    when label = '고1' then
      jsonb_build_object('grade_key', 'H1', 'course_key', '', 'course_label', coalesce(nullif(trim(raw_label), ''), '고1'))
    when label = '고2' then
      jsonb_build_object('grade_key', 'H2', 'course_key', '', 'course_label', coalesce(nullif(trim(raw_label), ''), '고2'))
    when label = '고3' then
      jsonb_build_object('grade_key', 'H3', 'course_key', '', 'course_label', coalesce(nullif(trim(raw_label), ''), '고3'))
    else
      jsonb_build_object('grade_key', '', 'course_key', '', 'course_label', coalesce(nullif(trim(raw_label), ''), ''))
  end
  from norm;
$$;

alter table public.textbook_metadata
  add column if not exists grade_key text not null default '',
  add column if not exists course_key text not null default '',
  add column if not exists course_label text not null default '';

alter table public.resource_file_links
  add column if not exists grade_key text not null default '',
  add column if not exists course_key text not null default '',
  add column if not exists course_label text not null default '';

alter table public.textbook_pb_extract_runs
  add column if not exists grade_key text not null default '',
  add column if not exists course_key text not null default '',
  add column if not exists course_label text not null default '';

create index if not exists textbook_metadata_course_key_idx
  on public.textbook_metadata(academy_id, course_key)
  where course_key <> '';

create index if not exists resource_file_links_course_key_idx
  on public.resource_file_links(academy_id, course_key)
  where course_key <> '';

create index if not exists textbook_pb_extract_runs_course_key_idx
  on public.textbook_pb_extract_runs(academy_id, course_key)
  where course_key <> '';

-- Seed the course options table used by the manager/learning UI. The historic
-- column is named grade_key, but it is used as the stable option key here.
insert into public.answer_key_grades (academy_id, grade_key, label, order_index)
select a.id, v.course_key, v.course_label, v.order_index
from public.academies a
cross join (
  values
    ('M1-1', '1-1', 101),
    ('M1-2', '1-2', 102),
    ('M2-1', '2-1', 201),
    ('M2-2', '2-2', 202),
    ('M3-1', '3-1', 301),
    ('M3-2', '3-2', 302),
    ('H1-c1', '공통수학1', 401),
    ('H1-c2', '공통수학2', 402),
    ('H-algebra', '대수', 501),
    ('H-calc1', '미적분1', 502),
    ('H-probstats', '확률과 통계', 503),
    ('H-calc2', '미적분2', 504),
    ('H-geometry', '기하', 505)
) as v(course_key, course_label, order_index)
on conflict (academy_id, grade_key) do update
set label = excluded.label,
    order_index = excluded.order_index,
    updated_at = now();

update public.textbook_metadata tm
set
  grade_key = coalesce(nullif(tm.grade_key, ''), public._textbook_course_info(tm.grade_label)->>'grade_key', ''),
  course_key = coalesce(nullif(tm.course_key, ''), public._textbook_course_info(tm.grade_label)->>'course_key', ''),
  course_label = coalesce(nullif(tm.course_label, ''), public._textbook_course_info(tm.grade_label)->>'course_label', ''),
  payload = jsonb_strip_nulls(
    coalesce(tm.payload, '{}'::jsonb) ||
    jsonb_build_object(
      'grade_key', nullif(coalesce(nullif(tm.grade_key, ''), public._textbook_course_info(tm.grade_label)->>'grade_key', ''), ''),
      'course_key', nullif(coalesce(nullif(tm.course_key, ''), public._textbook_course_info(tm.grade_label)->>'course_key', ''), ''),
      'course_label', nullif(coalesce(nullif(tm.course_label, ''), public._textbook_course_info(tm.grade_label)->>'course_label', ''), '')
    )
  );

update public.resource_file_links rfl
set
  grade_key = coalesce(nullif(rfl.grade_key, ''), public._textbook_course_info(split_part(coalesce(rfl.grade, ''), '#', 1))->>'grade_key', ''),
  course_key = coalesce(nullif(rfl.course_key, ''), public._textbook_course_info(split_part(coalesce(rfl.grade, ''), '#', 1))->>'course_key', ''),
  course_label = coalesce(nullif(rfl.course_label, ''), public._textbook_course_info(split_part(coalesce(rfl.grade, ''), '#', 1))->>'course_label', '');

update public.textbook_pb_extract_runs run
set
  grade_key = coalesce(nullif(run.grade_key, ''), public._textbook_course_info(run.grade_label)->>'grade_key', ''),
  course_key = coalesce(nullif(run.course_key, ''), public._textbook_course_info(run.grade_label)->>'course_key', ''),
  course_label = coalesce(nullif(run.course_label, ''), public._textbook_course_info(run.grade_label)->>'course_label', '');

update public.pb_documents doc
set meta =
  jsonb_strip_nulls(
    coalesce(doc.meta, '{}'::jsonb) ||
    jsonb_build_object(
      'textbook_course',
      jsonb_build_object(
        'grade_key', nullif(public._textbook_course_info(doc.grade_label)->>'grade_key', ''),
        'course_key', nullif(public._textbook_course_info(doc.grade_label)->>'course_key', ''),
        'course_label', nullif(public._textbook_course_info(doc.grade_label)->>'course_label', '')
      ),
      'textbook_scope',
      coalesce(doc.meta->'textbook_scope', '{}'::jsonb) ||
      jsonb_build_object(
        'grade_key', nullif(public._textbook_course_info(doc.grade_label)->>'grade_key', ''),
        'course_key', nullif(public._textbook_course_info(doc.grade_label)->>'course_key', ''),
        'course_label', nullif(public._textbook_course_info(doc.grade_label)->>'course_label', '')
      )
    )
  )
where doc.source_type_code = 'market_book'
  and (
    coalesce(doc.meta->>'extract_mode', '') = 'textbook_pdf_only'
    or coalesce(doc.meta->'textbook_scope'->>'mode', '') = 'textbook_pdf_only'
  );

update public.pb_questions q
set meta =
  jsonb_strip_nulls(
    coalesce(q.meta, '{}'::jsonb) ||
    jsonb_build_object(
      'textbook_course',
      jsonb_build_object(
        'grade_key', nullif(public._textbook_course_info(q.grade_label)->>'grade_key', ''),
        'course_key', nullif(public._textbook_course_info(q.grade_label)->>'course_key', ''),
        'course_label', nullif(public._textbook_course_info(q.grade_label)->>'course_label', '')
      ),
      'textbook_scope',
      coalesce(q.meta->'textbook_scope', '{}'::jsonb) ||
      jsonb_build_object(
        'grade_key', nullif(public._textbook_course_info(q.grade_label)->>'grade_key', ''),
        'course_key', nullif(public._textbook_course_info(q.grade_label)->>'course_key', ''),
        'course_label', nullif(public._textbook_course_info(q.grade_label)->>'course_label', '')
      )
    )
  )
where q.source_type_code = 'market_book'
  and q.meta ? 'textbook_scope';
