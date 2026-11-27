-- 학생앱 하단 검색: 개념 이름만 찾고, Think 배지가 남은 배치는 뺀다.
-- Think 배지는 concept_appearances.origin = 'ai' 일 때 붙는다.
-- 운영자가 확인하면 origin이 owner가 되고 배지가 사라진다.
-- 한 개념에 확인 전 배치가 하나라도 있으면 검색에 넣지 않는다.

create or replace function public.student_search_concepts_v1(p_query text)
returns table(
  id uuid,
  name text,
  content text
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
  select c.id, c.name, c.content
  from public.concepts c
  where c.name ilike '%' || v_query || '%' escape '\'
    and not exists (
      select 1
      from public.concept_appearances a
      where a.concept_id = c.id
        and a.origin = 'ai'
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
  '학생앱 개념 검색. 이름만 보고, Think 배지(origin=ai)가 남은 개념은 뺀다.';
