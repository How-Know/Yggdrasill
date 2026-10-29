-- 1차 검수 3조건 미충족(first_pass = false)을 공개된 위치 행에서 위치 순으로 읽는다.
-- 새 사유를 만들지 않는다. 진단 컬럼도 만들지 않는다.
-- 페이지 크기는 null이면 50, 0 미만이면 0, 50을 넘으면 50이다. 0이면 이번 배열은 비고 total은 그대로다.
-- stable이라 이 호출의 질의는 같은 문장 스냅샷을 본다. 상태 함수를 부르지 않는다.

create or replace function public.concept_review_job_unmet_page(
  p_job_id uuid,
  p_version bigint default null,
  p_after integer default 0,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_dirty boolean := false;
  v_fresh text;
  v_after integer := greatest(coalesce(p_after, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 50), 0), 50);
  v_pub bigint;
  v_at text;
  v_total integer := 0;
  v_after_n integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_returned integer := 0;
  v_omitted integer := 0;
  v_next integer;
begin
  perform public.concept_review_assert_operator();
  if not exists (select 1 from public.concept_review_jobs where id = p_job_id) then
    raise exception 'concept_review_job_not_found';
  end if;

  select * into v_prog from public.concept_review_progress_jobs where job_id = p_job_id;
  if v_prog.active_run_id is not null then
    select * into v_run from public.concept_review_progress_runs where id = v_prog.active_run_id;
  end if;
  if v_prog.job_id is not null then
    v_dirty := exists (
      select 1 from public.concept_review_progress_positions
       where job_id = p_job_id and dirty_token > published_token
    );
  end if;
  v_fresh := case
    when v_prog.job_id is null then 'absent'
    when v_run.state = 'failed' and v_run.attempts >= 5 and v_run.input_version = v_prog.input_version then 'failed'
    when v_run.state = 'running' and v_run.input_version = v_prog.input_version then 'refreshing'
    when v_prog.published_input_version is not null
         and (v_prog.input_version is distinct from v_prog.published_input_version or v_dirty or v_prog.needs_rebuild) then 'stale'
    when v_prog.published_input_version is not null then 'current'
    else 'absent'
  end;
  v_pub := v_prog.published_input_version;
  v_at := v_prog.last_success ->> 'at';

  if v_fresh <> 'current'
     or (coalesce(p_after, 0) > 0 and p_version is null)
     or (p_version is not null and p_version is distinct from v_pub) then
    return jsonb_build_object(
      'code', case
        when v_fresh <> 'current' then v_fresh
        when coalesce(p_after, 0) > 0 and p_version is null then 'version_required'
        else 'snapshot_replaced'
      end,
      'published_input_version', v_pub,
      'snapshot_at', case when v_fresh = 'current' then v_at else null end,
      'total', null,
      'returned', null,
      'omitted', null,
      'next_after', null,
      'items', null,
      'progress_error', case when v_fresh = 'failed' then v_prog.progress_error else null end
    );
  end if;

  select count(*)::integer into v_total
    from public.concept_review_progress_positions
   where job_id = p_job_id and first_pass = false;

  select coalesce(jsonb_agg(x.obj order by x.pos), '[]'::jsonb)
    into v_items
    from (
      select p.pos,
             jsonb_build_object(
               'snapshot',
                 jsonb_build_object(
                   'pos', p.pos,
                   'concept_id', p.concept_id,
                   'category', p.category,
                   'cond_text', p.cond_text,
                   'cond_foundation', p.cond_foundation,
                   'cond_placement', p.cond_placement,
                   'first_pass', p.first_pass
                 ) || jsonb_strip_nulls(jsonb_build_object(
                   'name', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'name'), '') end,
                   'item_state', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'item_state'), '') end,
                   'reason', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'reason'), '') end,
                   'next_action', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'next_action'), '') end,
                   'conditions', case when p.open_payload is null then null else p.open_payload -> 'conditions' end,
                   'todo', case when p.open_payload is null then null else p.open_payload -> 'todo' end,
                   'open', case when p.open_payload is null then null else p.open_payload -> 'open' end
                 )),
               'supplement',
                 case
                   when p.open_payload is not null
                    and nullif(btrim(p.open_payload ->> 'name'), '') is not null
                    and nullif(btrim(p.open_payload ->> 'reason'), '') is not null
                   then null
                   else (
                     select jsonb_strip_nulls(jsonb_build_object(
                       'name', c.name,
                       'state', i.state,
                       'reason', nullif(btrim(i.reason), ''),
                       'next_action', nullif(btrim(i.next_action), ''),
                       'item_updated_at', i.updated_at
                     ))
                       from (select 1) s
                       left join public.concept_review_job_items i
                         on i.job_id = p.job_id and i.pos = p.pos
                       left join public.concepts c on c.id = p.concept_id
                   )
                 end
             ) as obj
        from public.concept_review_progress_positions p
       where p.job_id = p_job_id
         and p.first_pass = false
         and p.pos > v_after
       order by p.pos
       limit v_limit
    ) x;

  v_returned := coalesce(jsonb_array_length(v_items), 0);
  select count(*)::integer into v_after_n
    from public.concept_review_progress_positions
   where job_id = p_job_id and first_pass = false and pos > v_after;
  v_omitted := greatest(v_after_n - v_returned, 0);
  v_next := null;
  if v_omitted > 0 and v_returned > 0 then
    v_next := (v_items -> (v_returned - 1) -> 'snapshot' ->> 'pos')::integer;
  end if;

  return jsonb_build_object(
    'code', 'ok',
    'published_input_version', v_pub,
    'snapshot_at', v_at,
    'total', v_total,
    'returned', v_returned,
    'omitted', v_omitted,
    'next_after', v_next,
    'items', coalesce(v_items, '[]'::jsonb),
    'progress_error', null
  );
end;
$fn$;

revoke all on function public.concept_review_job_unmet_page(uuid, bigint, integer, integer) from public, anon;
grant execute on function public.concept_review_job_unmet_page(uuid, bigint, integer, integer) to authenticated;

notify pgrst, 'reload schema';
