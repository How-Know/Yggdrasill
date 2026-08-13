-- 학습 세션에 수행 장소를 실제로 채운다.
--
-- learning_sessions.location_kind 는 처음부터 있었지만 'unknown' 으로만
-- 들어가고 있었다. 출결로 판정해 채워 두면 같은 채점이라도 학원에서 한 것과
-- 집에서 무감독으로 한 것이 신뢰도 계산에서 갈린다.

create or replace function public._learning_session_fill_location()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.location_kind, 'unknown') = 'unknown'
     and new.student_id is not null then
    new.location_kind := public._student_location_kind(
      new.academy_id,
      new.student_id,
      coalesce(new.started_at, now())
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_learning_sessions_fill_location on public.learning_sessions;
create trigger trg_learning_sessions_fill_location
  before insert on public.learning_sessions
  for each row
  execute function public._learning_session_fill_location();

-- 하원하면 열려 있는 세션을 닫는다.
-- learning_log_homework_attempt 는 12시간 안의 열린 세션을 재사용하므로,
-- 닫아 두지 않으면 집에서 이어 푼 기록이 학원 세션에 섞여 장소가 뒤바뀐다.
create or replace function public._learning_close_sessions_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.departure_time is null or old.departure_time is not null then
    return new;
  end if;

  update public.learning_sessions s
  set status = 'completed',
      ended_at = coalesce(s.ended_at, least(new.departure_time, now())),
      elapsed_sec = coalesce(
        s.elapsed_sec,
        greatest(
          0,
          floor(
            extract(epoch from (least(new.departure_time, now()) - s.started_at))
          )::integer
        )
      ),
      updated_at = now()
  where s.academy_id = new.academy_id
    and s.student_id = new.student_id
    and s.status = 'open';

  return new;
end;
$$;

drop trigger if exists trg_learning_close_sessions_on_departure
  on public.attendance_records;
create trigger trg_learning_close_sessions_on_departure
  after update of departure_time on public.attendance_records
  for each row
  execute function public._learning_close_sessions_on_departure();
