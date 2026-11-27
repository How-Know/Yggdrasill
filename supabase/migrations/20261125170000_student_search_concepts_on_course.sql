-- 학생 개념 검색을 교육과정 흐름 기준으로 바꾼다.
-- 단원에 놓인 줄만 찾고, Think 배지(origin = ai)가 하나라도 남은 개념은 뺀다.
-- 반환에 유형·기존 구분(정의/연산/정리)·등장 과정을 더한다.

drop function if exists public.student_search_concepts_v1(text);

create function public.student_search_concepts_v1(p_query text)
returns table(
  id uuid,
  name text,
  content text,
  type_name text,
  group_name text,
  courses text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_query text;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  v_query := btrim(coalesce(p_query, ''));
  if char_length(v_query) < 1 then
    return;
  end if;
  if char_length(v_query) > 40 then
    v_query := left(v_query, 40);
  end if;
  v_query := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');

  return query
  select
    c.id,
    c.name,
    c.content,
    coalesce(nullif(btrim(t.name), ''), '') as type_name,
    coalesce(
      nullif(btrim(t.legacy_sub_type), ''),
      nullif(btrim(c.sub_type), ''),
      case c.kind
        when 'definition' then '정의'
        when 'theorem' then '정리'
        else ''
      end
    ) as group_name,
    coalesce((
      select string_agg(distinct placed.course_label, ' · ' order by placed.course_label)
      from public.concept_appearances placed
      where placed.concept_id = c.id
        and placed.course_unit_id is not null
        and placed.origin = 'owner'
        and btrim(placed.course_label) <> ''
    ), '') as courses
  from public.concepts c
  left join public.concept_type_links link on link.concept_id = c.id
  left join public.concept_types t on t.id = link.type_id
  where c.name ilike '%' || v_query || '%' escape '\'
    and exists (
      select 1
      from public.concept_appearances placed
      where placed.concept_id = c.id
        and placed.course_unit_id is not null
        and placed.origin = 'owner'
    )
    and not exists (
      select 1
      from public.concept_appearances pending
      where pending.concept_id = c.id
        and pending.course_unit_id is not null
        and pending.origin = 'ai'
    )
  order by
    (c.name ilike v_query || '%' escape '\') desc,
    char_length(c.name),
    c.name
  limit 30;
end;
$$;

revoke all on function public.student_search_concepts_v1(text) from public, anon;
grant execute on function public.student_search_concepts_v1(text) to authenticated;

comment on function public.student_search_concepts_v1(text) is
  '학생앱 개념 검색. 교육과정 흐름에 놓이고 Think 배지가 없는 개념만, 이름만 찾는다.';
