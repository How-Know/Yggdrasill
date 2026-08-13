-- 수행 중 진행 상황을 30초마다 서버에 찍고, 신호가 끊긴 타이머를 마감한다.
--
-- 지금까지 학습 시간은 일시정지·단계전환 RPC 를 부를 때만 서버에 반영됐다.
-- 그래서 앱이 죽으면 마지막 정지 이후 구간이 통째로 사라졌고, 반대로 타이머가
-- 켜진 채 방치되면 무한정 늘어났다.
--
-- iOS 는 백그라운드 중단과 강제 종료를 구분해 주지 않는다. 신호가 끊겼다고
-- 바로 멈추면 잠금화면(라이브 액티비티)에서 이어 하는 흐름이 깨지므로,
-- 상한(기본 3시간)까지는 수행 중으로 두고 넘으면 마지막 신호 시점으로 마감한다.

-- ---------------------------------------------------------------------------
-- 1) 지정 시점으로 타이머를 끊는 공통 처리
-- ---------------------------------------------------------------------------
create or replace function public._homework_stop_run_at(
  p_item_id uuid,
  p_at timestamptz,
  p_reason text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.homework_items%rowtype;
  v_cut timestamptz;
  v_group_id uuid;
begin
  select * into v_item
  from public.homework_items
  where id = p_item_id
  for update;

  if v_item.id is null then
    return;
  end if;

  v_cut := least(
    now(),
    greatest(coalesce(p_at, now()), coalesce(v_item.run_start, coalesce(p_at, now())))
  );

  -- run_start 를 지우기 전에 구간을 닫아야 마감 시각이 now() 로 밀리지 않는다.
  perform public._homework_close_interval(p_item_id, v_cut, p_reason);

  update public.homework_items h
  set accumulated_ms = coalesce(h.accumulated_ms, 0)
        + case
            when h.run_start is not null then greatest(
              0,
              floor(extract(epoch from (greatest(v_cut, h.run_start) - h.run_start)) * 1000)::bigint
            )
            else 0
          end,
      run_start = null,
      phase = case when coalesce(h.phase, 1) = 2 then 1 else h.phase end,
      waiting_at = case when coalesce(h.phase, 1) = 2 then now() else h.waiting_at end,
      updated_at = now(),
      version = coalesce(h.version, 1) + 1
  where h.id = p_item_id
    and h.completed_at is null;

  if coalesce(v_item.phase, 1) = 2 then
    perform public._append_homework_phase_event(
      v_item.academy_id, p_item_id, 1::smallint, p_reason
    );
  end if;

  for v_group_id in
    select distinct gi.group_id
    from public.homework_group_items gi
    where gi.academy_id = v_item.academy_id
      and gi.homework_item_id = p_item_id
  loop
    perform public.m5_group_runtime_sync_from_children(
      v_item.academy_id, v_group_id, now()
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) 무응답 상한을 넘긴 타이머 마감
-- ---------------------------------------------------------------------------
create or replace function public.homework_sweep_stale_runs(
  p_max_idle interval default interval '3 hours'
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_count integer := 0;
begin
  for v_row in
    select i.item_id, greatest(i.last_beat_at, i.started_at) as cut_at
    from public.homework_study_intervals i
    where i.ended_at is null
      and i.last_beat_at < now() - p_max_idle
    order by i.last_beat_at
    limit 500
  loop
    perform public._homework_stop_run_at(v_row.item_id, v_row.cut_at, 'stale');
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) 학생앱 30초 신호
-- ---------------------------------------------------------------------------
create or replace function public.student_homework_beat()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_running integer := 0;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;

  update public.homework_study_intervals i
  set last_beat_at = now(),
      updated_at = now()
  from public.homework_items h
  where i.item_id = h.id
    and i.academy_id = v_academy
    and i.student_id = v_student
    and i.ended_at is null
    and h.run_start is not null;

  get diagnostics v_running = row_count;

  -- 방치된 타이머는 누구든 접속할 때 함께 정리한다 (별도 스케줄러 불필요).
  perform public.homework_sweep_stale_runs();

  return jsonb_build_object(
    'ok', true,
    'running_items', v_running,
    'beat_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 되감기 — 앱이 죽었다가 돌아왔을 때
-- ---------------------------------------------------------------------------
-- 복귀했는데 라이브 액티비티가 사라져 있으면 그 사이는 공부한 것으로 볼 수
-- 없다. 마지막으로 신호를 보낸 시점까지만 인정하고 멈춘다.
create or replace function public.student_homework_rewind(
  p_reason text default 'app_closed'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_row record;
  v_count integer := 0;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;

  for v_row in
    select i.item_id, greatest(i.last_beat_at, i.started_at) as cut_at
    from public.homework_study_intervals i
    join public.homework_items h on h.id = i.item_id
    where i.academy_id = v_academy
      and i.student_id = v_student
      and i.ended_at is null
      and h.run_start is not null
  loop
    perform public._homework_stop_run_at(
      v_row.item_id,
      v_row.cut_at,
      coalesce(nullif(trim(p_reason), ''), 'app_closed')
    );
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'stopped_items', v_count);
end;
$$;

revoke all on function public.homework_sweep_stale_runs(interval) from public;
grant execute on function public.homework_sweep_stale_runs(interval)
  to anon, authenticated;

revoke all on function public.student_homework_beat() from public;
grant execute on function public.student_homework_beat() to authenticated;

revoke all on function public.student_homework_rewind(text) from public;
grant execute on function public.student_homework_rewind(text) to authenticated;
