-- Normalize problem-bank school level / grade / course keys.
-- Keep existing labels for display/search, and add stable keys for filtering.

alter table public.pb_documents
  add column if not exists school_level text not null default '',
  add column if not exists grade_key text not null default '',
  add column if not exists course_key text not null default '';

alter table public.pb_questions
  add column if not exists school_level text not null default '',
  add column if not exists grade_key text not null default '',
  add column if not exists course_key text not null default '';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pb_documents_school_level_chk'
  ) then
    alter table public.pb_documents
      add constraint pb_documents_school_level_chk
      check (school_level in ('', 'elementary', 'middle', 'high'));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'pb_questions_school_level_chk'
  ) then
    alter table public.pb_questions
      add constraint pb_questions_school_level_chk
      check (school_level in ('', 'elementary', 'middle', 'high'));
  end if;
end $$;

create or replace function public._pb_school_level_from_values(
  raw_school_level text,
  raw_grade_key text,
  raw_course_key text,
  raw_grade_label text,
  raw_course_label text
) returns text
language sql
immutable
as $$
  with norm as (
    select
      trim(coalesce(raw_school_level, '')) as school_level,
      upper(trim(coalesce(raw_grade_key, ''))) as grade_key,
      upper(trim(coalesce(raw_course_key, ''))) as course_key,
      replace(trim(coalesce(raw_grade_label, '')), ' ', '') as grade_label,
      replace(trim(coalesce(raw_course_label, '')), ' ', '') as course_label
  )
  select case
    when school_level in ('elementary', 'middle', 'high') then school_level
    when grade_key like 'E%' then 'elementary'
    when grade_key like 'M%' then 'middle'
    when grade_key like 'H%' then 'high'
    when course_key like 'M%' then 'middle'
    when course_key like 'H%' then 'high'
    when grade_label like '%초%' then 'elementary'
    when grade_label like '%중%' then 'middle'
    when grade_label like '%고%' then 'high'
    when course_label ~ '^(1|2|3)-[12]$' then 'middle'
    when course_label in ('공통수학1', '공통수학2', '대수', '미적분1', '미적분2', '확률과통계', '확률통계', '확통', '기하') then 'high'
    else ''
  end
  from norm;
$$;

create or replace function public._pb_grade_key_from_values(
  raw_school_level text,
  raw_grade_key text,
  raw_course_key text,
  raw_grade_label text,
  raw_course_label text
) returns text
language sql
stable
as $$
  with norm as (
    select
      public._pb_school_level_from_values(
        raw_school_level,
        raw_grade_key,
        raw_course_key,
        raw_grade_label,
        raw_course_label
      ) as school_level,
      upper(trim(coalesce(raw_grade_key, ''))) as grade_key,
      trim(coalesce(raw_course_key, '')) as course_key,
      trim(coalesce(raw_grade_label, '')) as grade_label,
      trim(coalesce(raw_course_label, '')) as course_label
  ),
  course_info as (
    select
      norm.*,
      public._textbook_course_info(norm.course_label) as info
    from norm
  )
  select case
    when grade_key <> '' then grade_key
    when school_level = 'middle' then
      case
        when grade_label ~ '[1-3]' then 'M' || substring(grade_label from '[1-3]')
        when course_label ~ '[1-3]' then 'M' || substring(course_label from '[1-3]')
        else ''
      end
    when school_level = 'high' then
      case
        when grade_label ~ '[1-3]' then 'H' || substring(grade_label from '[1-3]')
        when coalesce(info->>'grade_key', '') <> '' then info->>'grade_key'
        else ''
      end
    when coalesce(info->>'grade_key', '') <> '' then info->>'grade_key'
    else ''
  end
  from course_info;
$$;

create or replace function public._pb_course_key_from_values(
  raw_school_level text,
  raw_grade_key text,
  raw_course_key text,
  raw_grade_label text,
  raw_course_label text,
  raw_semester_label text
) returns text
language sql
stable
as $$
  with norm as (
    select
      public._pb_school_level_from_values(
        raw_school_level,
        raw_grade_key,
        raw_course_key,
        raw_grade_label,
        raw_course_label
      ) as school_level,
      public._pb_grade_key_from_values(
        raw_school_level,
        raw_grade_key,
        raw_course_key,
        raw_grade_label,
        raw_course_label
      ) as grade_key,
      trim(coalesce(raw_course_key, '')) as course_key,
      trim(coalesce(raw_course_label, '')) as course_label,
      trim(coalesce(raw_semester_label, '')) as semester_label
  ),
  course_info as (
    select
      norm.*,
      public._textbook_course_info(norm.course_label) as info
    from norm
  )
  select case
    when course_key <> '' then course_key
    when coalesce(info->>'course_key', '') <> '' then info->>'course_key'
    when school_level = 'middle' and grade_key ~ '^M[1-3]$' then
      grade_key || '-' || case when semester_label = '2학기' then '2' else '1' end
    when school_level = 'high' and grade_key = 'H1' then
      case when semester_label = '2학기' then 'H1-c2' else 'H1-c1' end
    else ''
  end
  from course_info;
$$;

create or replace function public._pb_course_label_from_key(
  raw_course_key text,
  fallback_label text
) returns text
language sql
immutable
as $$
  select case trim(coalesce(raw_course_key, ''))
    when 'M1-1' then '1-1'
    when 'M1-2' then '1-2'
    when 'M2-1' then '2-1'
    when 'M2-2' then '2-2'
    when 'M3-1' then '3-1'
    when 'M3-2' then '3-2'
    when 'H1-c1' then '공통수학1'
    when 'H1-c2' then '공통수학2'
    when 'H-algebra' then '대수'
    when 'H-calc1' then '미적분1'
    when 'H-probstats' then '확률과 통계'
    when 'H-calc2' then '미적분2'
    when 'H-geometry' then '기하'
    else trim(coalesce(fallback_label, ''))
  end;
$$;

with normalized as (
  select
    id,
    public._pb_school_level_from_values(
      school_level,
      grade_key,
      course_key,
      grade_label,
      course_label
    ) as resolved_school_level,
    public._pb_grade_key_from_values(
      school_level,
      grade_key,
      course_key,
      grade_label,
      course_label
    ) as resolved_grade_key,
    public._pb_course_key_from_values(
      school_level,
      grade_key,
      course_key,
      grade_label,
      course_label,
      semester_label
    ) as resolved_course_key
  from public.pb_documents
)
update public.pb_documents d
set
  school_level = case
    when normalized.resolved_school_level <> '' then normalized.resolved_school_level
    when d.source_type_code = 'school_past' then 'middle'
    else d.school_level
  end,
  grade_key = normalized.resolved_grade_key,
  course_key = normalized.resolved_course_key,
  course_label = case
    when trim(coalesce(d.course_label, '')) = '' and normalized.resolved_course_key <> ''
      then public._pb_course_label_from_key(normalized.resolved_course_key, d.course_label)
    else d.course_label
  end,
  semester_label = case
    when d.source_type_code = 'school_past' and d.semester_label = '' then '1학기'
    else d.semester_label
  end,
  exam_term_label = case
    when d.source_type_code = 'school_past' and d.exam_term_label = '' then '중간'
    else d.exam_term_label
  end,
  classification_detail = coalesce(d.classification_detail, '{}'::jsonb) ||
    jsonb_build_object(
      'school_level', case
        when normalized.resolved_school_level <> '' then normalized.resolved_school_level
        when d.source_type_code = 'school_past' then 'middle'
        else d.school_level
      end,
      'grade_key', normalized.resolved_grade_key,
      'course_key', normalized.resolved_course_key
    )
from normalized
where d.id = normalized.id;

update public.pb_documents d
set
  grade_key = case
    when d.grade_key = '' then public._pb_grade_key_from_values(
      d.school_level,
      d.grade_key,
      d.course_key,
      d.grade_label,
      d.course_label
    )
    else d.grade_key
  end,
  course_key = public._pb_course_key_from_values(
    d.school_level,
    case
      when d.grade_key = '' then public._pb_grade_key_from_values(
        d.school_level,
        d.grade_key,
        d.course_key,
        d.grade_label,
        d.course_label
      )
      else d.grade_key
    end,
    d.course_key,
    d.grade_label,
    d.course_label,
    d.semester_label
  ),
  course_label = case
    when trim(coalesce(d.course_label, '')) = '' then public._pb_course_label_from_key(
      public._pb_course_key_from_values(
        d.school_level,
        case
          when d.grade_key = '' then public._pb_grade_key_from_values(
            d.school_level,
            d.grade_key,
            d.course_key,
            d.grade_label,
            d.course_label
          )
          else d.grade_key
        end,
        d.course_key,
        d.grade_label,
        d.course_label,
        d.semester_label
      ),
      d.course_label
    )
    else d.course_label
  end
where d.source_type_code = 'school_past'
  and d.school_level = 'middle'
  and d.course_key = '';

update public.pb_questions q
set
  school_level = d.school_level,
  grade_key = d.grade_key,
  course_key = d.course_key,
  course_label = d.course_label,
  grade_label = d.grade_label,
  semester_label = d.semester_label,
  exam_term_label = d.exam_term_label,
  classification_detail = coalesce(q.classification_detail, '{}'::jsonb) ||
    jsonb_build_object(
      'school_level', d.school_level,
      'grade_key', d.grade_key,
      'course_key', d.course_key,
      'synced_normalized_course_from_document', true
    )
from public.pb_documents d
where q.document_id = d.id;

create index if not exists idx_pb_documents_normalized_course_filter
  on public.pb_documents (
    academy_id,
    curriculum_code,
    source_type_code,
    school_level,
    grade_key,
    course_key,
    exam_year desc,
    created_at desc
  );

create index if not exists idx_pb_questions_normalized_course_filter
  on public.pb_questions (
    academy_id,
    curriculum_code,
    source_type_code,
    school_level,
    grade_key,
    course_key,
    exam_year desc,
    created_at desc
  );
