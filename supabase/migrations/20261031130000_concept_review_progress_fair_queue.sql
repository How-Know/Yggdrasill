-- 20261031130000: 진행률 집계 대기열 선점(Head-of-Line Blocking) 및 비-rebuild 공회전 방지
--
-- 1) concept_review_progress_bump:
--    이미 대기열에 있는 작업에 추가 저장·승인이 들어와도 기존 enqueued_at 순번을 뒤로 밀지 않는다.
-- 2) concept_review_progress_step:
--    - p_job_id가 null(pg_cron 호출)일 때, 이미 공개 스냅샷이 있는 partial·resummarize 대상 작업을
--      대규모 초기 rebuild 작업보다 먼저 선택한다.
--    - 한 구간(chunk)만 처리하고 남았을 때(more = true) enqueued_at을 갱신해 라운드로빈으로 다음 작업에 양보한다.
--    - 비-rebuild 실행 중 pos_count <> walk_n 이면 즉시 superseded 처리하고 rebuild로 전환해 공회전을 막는다.
-- 3) pg_cron:
--    구간 크기를 20에서 100으로 올려 대량 작업의 집계 지연을 줄인다.

create or replace function public.concept_review_progress_bump(p_jobs uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if p_jobs is null or cardinality(p_jobs) = 0 then
    return;
  end if;
  insert into public.concept_review_progress_jobs (job_id, input_version)
  select distinct u.id, 1 from unnest(p_jobs) as u(id) where u.id is not null
  on conflict (job_id) do update
    set input_version = public.concept_review_progress_jobs.input_version + 1,
        progress_error = null,
        updated_at = now();
  insert into public.concept_review_progress_queue (job_id)
  select distinct u.id from unnest(p_jobs) as u(id) where u.id is not null
  on conflict (job_id) do update
    set attempts = 0, next_attempt_at = null, last_error = null;
  update public.concept_review_progress_runs r
     set state = 'superseded', finished_at = now()
   where r.job_id = any (p_jobs) and r.state = 'failed';
  update public.concept_review_progress_jobs p
     set active_run_id = null
   where p.job_id = any (p_jobs)
     and exists (
       select 1 from public.concept_review_progress_runs r
        where r.id = p.active_run_id and r.state <> 'running'
     );
end;
$fn$;

create or replace function public.concept_review_progress_step(p_job_id uuid default null, p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_job uuid := p_job_id;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_walk uuid[];
  v_walk_n integer;
  v_pos_n integer;
  v_dirty boolean;
  v_pending uuid[];
  v_row jsonb;
  v_token bigint;
  v_pos integer;
  v_cid uuid;
  v_processed integer := 0;
  v_next integer;
  v_err text;
  v_attempts integer;
begin
  perform public.concept_review_progress_assert_runner();
  if v_job is null then
    select q.job_id into v_job
      from public.concept_review_progress_queue q
      left join public.concept_review_progress_jobs pj on pj.job_id = q.job_id
      left join public.concept_review_progress_runs ar on ar.id = pj.active_run_id
     where q.attempts < 5
       and (q.next_attempt_at is null or q.next_attempt_at <= now())
     order by
       case
         when coalesce(pj.needs_rebuild, true) or ar.kind = 'rebuild' or pj.published_input_version is null then 1
         else 0
       end,
       q.enqueued_at,
       q.job_id
     limit 1;
    if v_job is null then
      return jsonb_build_object('outcome', 'idle', 'more', false, 'processed', 0);
    end if;
  end if;
  if not exists (select 1 from public.concept_review_jobs where id = v_job) then
    raise exception 'concept_review_job_not_found';
  end if;
  if not pg_try_advisory_xact_lock(hashtext('concept_review_progress'), hashtext(v_job::text)) then
    return jsonb_build_object('outcome', 'already_running', 'more', false, 'job_id', v_job, 'processed', 0);
  end if;

  begin
    select * into v_run from public.concept_review_progress_runs where false;
    insert into public.concept_review_progress_jobs (job_id, input_version)
    values (v_job, 0)
    on conflict (job_id) do nothing;
    select * into v_prog from public.concept_review_progress_jobs where job_id = v_job;
    select w.concept_ids, coalesce(cardinality(w.concept_ids), 0)
      into v_walk, v_walk_n
      from public.concept_review_jobs j
      join public.concept_review_walks w on w.id = j.walk_id
     where j.id = v_job;
    select count(*) into v_pos_n from public.concept_review_progress_positions where job_id = v_job;
    v_dirty := exists (
      select 1 from public.concept_review_progress_positions
       where job_id = v_job and dirty_token > published_token
    );

    select * into v_run from public.concept_review_progress_runs where false;
    if v_prog.active_run_id is not null then
      select * into v_run from public.concept_review_progress_runs where id = v_prog.active_run_id;
    end if;
    if v_run.id is not null and v_run.state = 'running'
       and (v_run.input_version is distinct from v_prog.input_version
            or (v_run.kind <> 'rebuild' and (v_prog.needs_rebuild or v_pos_n <> v_walk_n))) then
      update public.concept_review_progress_runs
         set state = 'superseded', finished_at = now()
       where id = v_run.id;
      delete from public.concept_review_progress_stage where run_id = v_run.id;
      update public.concept_review_progress_jobs set active_run_id = null where job_id = v_job;
      select * into v_run from public.concept_review_progress_runs where false;
    end if;
    if v_run.id is not null and v_run.state = 'failed' and v_run.attempts >= 5
       and v_run.input_version = v_prog.input_version then
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', 0,
        'error', coalesce(v_run.error, 'progress_step_failed'), 'freshness', 'failed'
      );
    end if;
    if v_run.id is not null and v_run.state = 'running' and v_run.attempts > 0
       and v_run.next_attempt_at > now() and v_run.input_version = v_prog.input_version then
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', 0,
        'error', coalesce(v_run.error, 'progress_step_failed')
      );
    end if;

    if v_run.id is null or v_run.state <> 'running' then
      if v_prog.needs_rebuild or v_pos_n <> v_walk_n then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'rebuild', v_prog.input_version, 'running', 1)
        returning * into v_run;
      elsif v_dirty then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'partial', v_prog.input_version, 'running', 1)
        returning * into v_run;
      elsif v_prog.published_input_version is distinct from v_prog.input_version then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'resummarize', v_prog.input_version, 'running', 1)
        returning * into v_run;
      else
        delete from public.concept_review_progress_queue where job_id = v_job;
        return jsonb_build_object('outcome', 'idle', 'more', false, 'job_id', v_job, 'processed', 0, 'freshness', 'current');
      end if;
      update public.concept_review_progress_jobs set active_run_id = v_run.id, updated_at = now() where job_id = v_job;
    end if;

    if v_run.kind = 'resummarize' then
      if public.concept_review_progress_finish(v_job, v_run.id) then
        return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', 0, 'freshness', 'current');
      end if;
      return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', 0);
    end if;

    v_pending := public.concept_review_pending_concepts();
    if v_run.kind = 'rebuild' then
      for v_pos, v_cid in
        select u.pos::integer, u.cid
          from unnest(v_walk) with ordinality as u(cid, pos)
         where u.pos >= v_run.cursor_pos
         order by u.pos
         limit v_limit
      loop
        v_row := public.concept_review_progress_judge(v_job, v_pos, v_pending);
        insert into public.concept_review_progress_stage (
          run_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass, first_pass_gap, open_payload
        ) values (
          v_run.id, v_pos, (v_row ->> 'concept_id')::uuid, v_row ->> 'category',
          coalesce((v_row ->> 'cond_text')::boolean, false),
          coalesce((v_row ->> 'cond_foundation')::boolean, false),
          coalesce((v_row ->> 'cond_placement')::boolean, false),
          coalesce((v_row ->> 'first_pass')::boolean, false),
          coalesce((v_row ->> 'first_pass_gap')::boolean, false),
          v_row -> 'open_payload'
        )
        on conflict (run_id, pos) do update
          set concept_id = excluded.concept_id, category = excluded.category,
              cond_text = excluded.cond_text, cond_foundation = excluded.cond_foundation,
              cond_placement = excluded.cond_placement, first_pass = excluded.first_pass, first_pass_gap = excluded.first_pass_gap,
              open_payload = excluded.open_payload;
        v_processed := v_processed + 1;
        v_next := v_pos + 1;
      end loop;
      if v_processed = 0 and v_run.cursor_pos <= v_walk_n then
        raise exception 'progress_cursor_stuck';
      end if;
      update public.concept_review_progress_runs
         set cursor_pos = coalesce(v_next, v_run.cursor_pos), updated_at = now(), attempts = 0, next_attempt_at = null, error = null
       where id = v_run.id;
      if coalesce(v_next, v_run.cursor_pos) > v_walk_n or v_walk_n = 0 then
        if public.concept_review_progress_finish(v_job, v_run.id) then
          return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', v_processed, 'freshness', 'current');
        end if;
        return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', 0);
      end if;
      update public.concept_review_progress_queue set enqueued_at = now() where job_id = v_job;
      return jsonb_build_object('outcome', 'chunk', 'more', true, 'job_id', v_job, 'processed', v_processed, 'cursor', v_next, 'freshness', 'refreshing');
    end if;

    for v_pos, v_token in
      select p.pos, p.dirty_token
        from public.concept_review_progress_positions p
       where p.job_id = v_job and p.dirty_token > p.published_token
       order by p.pos
       limit v_limit
    loop
      v_row := public.concept_review_progress_judge(v_job, v_pos, v_pending);
      update public.concept_review_progress_positions
         set concept_id = (v_row ->> 'concept_id')::uuid,
             category = v_row ->> 'category',
             cond_text = coalesce((v_row ->> 'cond_text')::boolean, false),
             cond_foundation = coalesce((v_row ->> 'cond_foundation')::boolean, false),
             cond_placement = coalesce((v_row ->> 'cond_placement')::boolean, false),
             first_pass = coalesce((v_row ->> 'first_pass')::boolean, false),
             first_pass_gap = coalesce((v_row ->> 'first_pass_gap')::boolean, false),
             open_payload = v_row -> 'open_payload',
             published_token = v_token
       where job_id = v_job and pos = v_pos and dirty_token = v_token;
      if found then
        perform public.concept_review_progress_refresh_deps(v_job, v_pos);
        v_processed := v_processed + 1;
      end if;
    end loop;
    update public.concept_review_progress_runs
       set updated_at = now(), attempts = 0, next_attempt_at = null, error = null
     where id = v_run.id;
    if public.concept_review_progress_finish(v_job, v_run.id) then
      return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', v_processed, 'freshness', 'current');
    end if;
    if exists (
      select 1 from public.concept_review_progress_runs r
       where r.id = v_run.id and r.state = 'running'
    ) and exists (
      select 1 from public.concept_review_progress_positions
       where job_id = v_job and dirty_token > published_token
    ) then
      update public.concept_review_progress_queue set enqueued_at = now() where job_id = v_job;
      return jsonb_build_object('outcome', 'chunk', 'more', true, 'job_id', v_job, 'processed', v_processed, 'freshness', 'refreshing');
    end if;
    return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', 0);
  exception
    when others then
      if sqlerrm in ('concept_review_forbidden', 'concept_review_job_not_found') then
        raise;
      end if;
      v_err := case when sqlerrm ~ '^[a-z][a-z0-9_]{0,80}$' then sqlerrm else 'progress_step_failed' end;
      v_attempts := coalesce(v_run.attempts, 0) + 1;
      if v_run.id is not null then
        update public.concept_review_progress_runs
           set attempts = v_attempts,
               error = v_err,
               next_attempt_at = now() + make_interval(mins => v_attempts),
               state = case when v_attempts >= 5 then 'failed' else 'running' end,
               updated_at = now(),
               finished_at = case when v_attempts >= 5 then now() else null end
         where id = v_run.id;
        update public.concept_review_progress_jobs
           set progress_error = v_err, updated_at = now()
         where job_id = v_job;
        update public.concept_review_progress_queue
           set attempts = v_attempts, next_attempt_at = now() + make_interval(mins => v_attempts), last_error = v_err
         where job_id = v_job;
      end if;
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', v_processed,
        'error', v_err, 'sqlstate', sqlstate, 'attempts', v_attempts
      );
  end;
end;
$fn$;

revoke all on function public.concept_review_progress_bump(uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_step(uuid, integer) from public, anon, service_role;
grant execute on function public.concept_review_progress_step(uuid, integer) to authenticated;

do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'concept-review-progress') then
      perform cron.unschedule('concept-review-progress');
    end if;
    perform cron.schedule(
      'concept-review-progress',
      '* * * * *',
      'select public.concept_review_progress_step(null, 100)'
    );
  end if;
exception when others then
  raise notice 'concept_review_progress cron not scheduled: %', sqlerrm;
end
$cron$;

notify pgrst, 'reload schema';
