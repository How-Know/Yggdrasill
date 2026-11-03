-- 20261103180000: 개념 검수 작업 상태 조회(concept_review_job_status) — open_items 에서 1차 검수 미충족(not first_pass) 및 drafted 항목 우선 반환
--
-- 기존 concept_review_job_status 는 category in ('open', 'drafted', 'todo') 를 단순히 pos 순으로 20개만 잘라 반환해,
-- 앞쪽 위치에 1차 검수 3조건을 이미 충족(first_pass = true)하고 선택 범위(unit/relations/classification)나 gap 만 남은 항목이 20개 이상 있으면
-- 정작 뒤쪽 위치의 1차 검수 미충족(first_pass = false) 항목이나 미제출 초안(drafted)이 open_items 에서 밀려 보이지 않던 문제를 고친다.
-- 정렬 기준: (1) not first_pass 우선, (2) drafted 우선, (3) pos 순.

create or replace function public.concept_review_job_status(p_job_id uuid, p_open_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_limit integer := least(greatest(coalesce(p_open_limit, 20), 0), 60);
  v_dirty boolean := false;
  v_fresh text;
  v_open jsonb := '[]'::jsonb;
  v_cards jsonb;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
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
  if v_fresh = 'current' then
    select coalesce(jsonb_agg(s.open_payload order by s.pos), '[]'::jsonb) into v_open
      from (
        select pos, open_payload
          from public.concept_review_progress_positions
         where job_id = p_job_id and category in ('open', 'drafted', 'todo') and open_payload is not null
         order by (not first_pass) desc, (category = 'drafted') desc, pos
         limit v_limit
      ) s;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'action_id', a.id, 'kind', a.kind, 'conversation_id', a.conversation_id, 'conversation_title', c.title,
           'created_at', a.created_at, 'items', jsonb_array_length(coalesce(a.payload -> 'items', '[]'::jsonb)),
           'linked', jc.action_id is not null, 'legacy', coalesce(jc.legacy, false)
         ) order by a.created_at), '[]'::jsonb) into v_cards
    from public.ai_actions a
    left join public.ai_conversations c on c.id = a.conversation_id
    left join public.concept_review_job_cards jc on jc.job_id = v_job.id and jc.action_id = a.id
   where a.status = 'proposed'
     and (jc.action_id is not null or (a.kind = 'concept_review_record' and exists (
       select 1 from jsonb_array_elements(
         case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
       ) x where public.course_think_uuid(x ->> 'concept_id') = any (v_walk.concept_ids)
     )));
  return jsonb_build_object(
    'job', jsonb_build_object(
      'job_id', v_job.id, 'title', v_job.title, 'status', v_job.status, 'pause_reason', v_job.pause_reason,
      'walk_id', v_job.walk_id, 'walk_created_at', v_walk.created_at, 'total', v_job.total,
      'served_through', v_job.served_through, 'checkpoint', v_job.checkpoint,
      'created_by_me', v_job.created_by = auth.uid(), 'created_at', v_job.created_at, 'updated_at', v_job.updated_at,
      'lease_active', v_job.lease_until > now(), 'auto_run', v_job.auto_run, 'limits', v_job.limits
    ),
    'walk_total', coalesce(cardinality(v_walk.concept_ids), 0),
    'progress_freshness', v_fresh,
    'progress_error', case when v_fresh = 'failed' then v_prog.progress_error else null end,
    'progress_last_success', case when v_fresh = 'current' then null else v_prog.last_success end,
    'total_mismatch', case when v_fresh = 'current' then v_prog.total_mismatch else null end,
    'counts', case when v_fresh = 'current' then v_prog.counts else null end,
    'conditions', case when v_fresh = 'current' then v_prog.conditions else null end,
    'progress_line', case when v_fresh = 'current' then v_prog.progress_line else null end,
    'condition_line', case when v_fresh = 'current' then v_prog.condition_line else null end,
    'open_items', case when v_fresh = 'current' then v_open else '[]'::jsonb end,
    'pending_cards', coalesce(v_cards, '[]'::jsonb),
    'first_pass', case when v_fresh = 'current' then v_prog.first_pass else null end,
    'first_pass_line', case when v_fresh = 'current' then v_prog.first_pass_line else null end
  );
end;
$fn$;

revoke all on function public.concept_review_job_status(uuid, integer) from public, anon;
grant execute on function public.concept_review_job_status(uuid, integer) to authenticated;

notify pgrst, 'reload schema';
