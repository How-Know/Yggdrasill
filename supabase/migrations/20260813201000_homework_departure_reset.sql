-- 하원하면 과제 타이머를 무조건 끊고 전부 대기(1)로 되돌린다.
--
-- 지금까지 이 정리는 매니저앱 하원 처리와 PC 알림장 인쇄 워커 안에만 있어서,
-- 키오스크로만 하원하고 PC 후처리가 돌지 않으면 타이머가 집에 가서도 계속
-- 돌았다. 출결에 하원이 찍히는 순간 DB 에서 직접 끊어 경로에 상관없이
-- 항상 같게 만든다.
--
-- 하원은 "하루의 마디"다. 여기서 한 번 끊고, 그 뒤 집에서 이어 하는 것은
-- 허용한다. 학원에서 한 시간과 집에서 한 시간은 구간 테이블로 갈린다.

create or replace function public._homework_reset_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cut timestamptz;
  v_item record;
begin
  if new.departure_time is null
     or old.departure_time is not null then
    return new;
  end if;

  -- 매니저가 과거 시각으로 하원을 적을 수 있다. 미래로는 넘기지 않는다.
  v_cut := least(new.departure_time, now());

  -- 1) 열려 있는 학습 구간을 하원 시각에 맞춰 닫는다.
  --    run_start 를 지우기 전에 해야 구간이 now() 가 아니라 하원 시각으로 남는다.
  for v_item in
    select i.item_id, h.run_start
    from public.homework_study_intervals i
    join public.homework_items h on h.id = i.item_id
    where i.academy_id = new.academy_id
      and i.student_id = new.student_id
      and i.ended_at is null
  loop
    perform public._homework_close_interval(
      v_item.item_id,
      greatest(v_cut, v_item.run_start),
      'departure'
    );
  end loop;

  -- 2) 돌고 있는 타이머를 하원 시각까지만 누적하고 멈춘다.
  update public.homework_items h
  set accumulated_ms = coalesce(h.accumulated_ms, 0)
        + greatest(
            0,
            floor(extract(epoch from (greatest(v_cut, h.run_start) - h.run_start)) * 1000)::bigint
          ),
      run_start = null,
      updated_at = now(),
      version = coalesce(h.version, 1) + 1
  where h.academy_id = new.academy_id
    and h.student_id = new.student_id
    and h.run_start is not null
    and h.completed_at is null;

  -- 3) 완료되지 않은 과제는 단계와 무관하게 전부 대기로 되돌린다.
  --    제출(3)·확인(4)도 포함한다 — 하원하면 그날의 검사는 끝난 것으로 보고,
  --    다음 등원 때 다시 제출하게 한다. 교재 제출 잠금도 함께 풀린다.
  with reset as (
    update public.homework_items h
    set phase = 1,
        run_start = null,
        waiting_at = now(),
        updated_at = now(),
        version = coalesce(h.version, 1) + 1
    where h.academy_id = new.academy_id
      and h.student_id = new.student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) not in (0, 1)
    returning h.id
  )
  insert into public.homework_item_phase_events (
    academy_id, item_id, phase, actor_user_id, note
  )
  select new.academy_id, r.id, 1::smallint, auth.uid(), 'departure_reset'
  from reset r;

  -- 4) 그룹 런타임도 같은 상태로 맞춘다.
  update public.homework_group_runtime r
  set accumulated_ms = coalesce(r.accumulated_ms, 0)
        + case
            when r.run_start is not null then greatest(
              0,
              floor(extract(epoch from (greatest(v_cut, r.run_start) - r.run_start)) * 1000)::bigint
            )
            else 0
          end,
      run_start = null,
      phase = 1,
      updated_at = now(),
      version = coalesce(r.version, 1) + 1
  where r.academy_id = new.academy_id
    and r.student_id = new.student_id
    and (r.phase <> 1 or r.run_start is not null);

  return new;
end;
$$;

drop trigger if exists trg_homework_reset_on_departure on public.attendance_records;
create trigger trg_homework_reset_on_departure
  after update of departure_time on public.attendance_records
  for each row
  execute function public._homework_reset_on_departure();
