-- Add aliases discovered during the first textbook course-key backfill.

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
    when label in ('확률과통계', '확률통계', '확통', '고2확률과통계', '고3확률과통계') then
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

update public.resource_file_links rfl
set
  grade_key = public._textbook_course_info(split_part(coalesce(rfl.grade, ''), '#', 1))->>'grade_key',
  course_key = public._textbook_course_info(split_part(coalesce(rfl.grade, ''), '#', 1))->>'course_key',
  course_label = public._textbook_course_info(split_part(coalesce(rfl.grade, ''), '#', 1))->>'course_label'
where rfl.course_key = ''
  and public._textbook_course_info(split_part(coalesce(rfl.grade, ''), '#', 1))->>'course_key' <> '';
