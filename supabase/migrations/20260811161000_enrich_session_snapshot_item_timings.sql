-- plan_details 각 항목에 이번 회차 채점 시간/횟수를 고정한다.
-- 스냅샷 실패가 하원 자체를 막지 않도록 하원 트리거는 best-effort로 보호한다.

create or replace function public._enrich_class_session_snapshot_details()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select coalesce(jsonb_agg(
    e.value || jsonb_build_object(
      'session_grading_attempt_count',
      (
        select count(*)::integer
        from public.homework_test_grading_attempts a
        where a.academy_id = new.academy_id
          and a.student_id = new.student_id
          and a.homework_item_id =
              nullif(e.value->>'homework_item_id', '')::uuid
          and a.graded_at >= new.arrival_time
          and a.graded_at <= new.departure_time
      ),
      'session_solve_elapsed_ms',
      (
        select coalesce(sum(a.solve_elapsed_ms), 0)::bigint
        from public.homework_test_grading_attempts a
        where a.academy_id = new.academy_id
          and a.student_id = new.student_id
          and a.homework_item_id =
              nullif(e.value->>'homework_item_id', '')::uuid
          and a.graded_at >= new.arrival_time
          and a.graded_at <= new.departure_time
      ),
      'session_extra_elapsed_ms',
      (
        select coalesce(sum(a.extra_elapsed_ms), 0)::bigint
        from public.homework_test_grading_attempts a
        where a.academy_id = new.academy_id
          and a.student_id = new.student_id
          and a.homework_item_id =
              nullif(e.value->>'homework_item_id', '')::uuid
          and a.graded_at >= new.arrival_time
          and a.graded_at <= new.departure_time
      )
    )
  ), '[]'::jsonb)
  into new.plan_details
  from jsonb_array_elements(coalesce(new.plan_details, '[]'::jsonb)) e(value);

  return new;
end;
$$;

drop trigger if exists trg_enrich_class_session_snapshot_details
  on public.student_class_session_snapshots;
create trigger trg_enrich_class_session_snapshot_details
before insert on public.student_class_session_snapshots
for each row
execute function public._enrich_class_session_snapshot_details();

create or replace function public._finalize_class_session_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.departure_time is not null
     and old.departure_time is null
     and new.arrival_time is not null then
    begin
      perform public.m5_finalize_class_session_snapshot(new.id);
    exception when others then
      raise warning
        'class session snapshot failed attendance=% error=%',
        new.id,
        sqlerrm;
    end;
  end if;
  return new;
end;
$$;
