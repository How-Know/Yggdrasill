-- 개념 검수 실패 사유 조회.
-- 진단은 항목 reason 문자열에만 있다. 이 함수는 그 문자열을 위치 순서대로 나눠 읽는다.
-- 실패 행을 고치거나 포괄 사유를 다시 쓰지 않는다.

create or replace function public.concept_review_job_failure_page(
  p_job_id uuid,
  p_after integer default 0,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 0), 50);
  v_after integer := greatest(coalesce(p_after, 0), 0);
  v_total integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_next integer;
begin
  perform public.concept_review_assert_operator();
  if not exists (select 1 from public.concept_review_jobs where id = p_job_id) then
    raise exception 'concept_review_job_not_found';
  end if;

  select count(*)::integer
    into v_total
    from public.concept_review_job_items i
   where i.job_id = p_job_id
     and i.state = 'failed'
     and i.pos > v_after;

  select coalesce(jsonb_agg(x.obj order by x.pos), '[]'::jsonb)
    into v_items
    from (
      select i.pos,
             jsonb_build_object(
               'position', i.pos,
               'concept_id', i.concept_id,
               'name', (select c.name from public.concepts c where c.id = i.concept_id),
               'reason', i.reason,
               'next_action', i.next_action
             ) as obj
        from public.concept_review_job_items i
       where i.job_id = p_job_id
         and i.state = 'failed'
         and i.pos > v_after
       order by i.pos
       limit v_limit
    ) x;

  v_next := null;
  if v_total > jsonb_array_length(v_items) and jsonb_array_length(v_items) > 0 then
    v_next := (v_items -> (jsonb_array_length(v_items) - 1) ->> 'position')::integer;
  end if;

  return jsonb_build_object(
    'returned', jsonb_array_length(v_items),
    'omitted', greatest(v_total - jsonb_array_length(v_items), 0),
    'next_after', v_next,
    'items', v_items
  );
end;
$$;

revoke all on function public.concept_review_job_failure_page(uuid, integer, integer) from public, anon;
grant execute on function public.concept_review_job_failure_page(uuid, integer, integer) to authenticated;

notify pgrst, 'reload schema';
