-- Auto-unbind device when a student's attendance departs (하원 시 매핑 해제)

create or replace function public._m5_auto_unbind_on_departure()
returns trigger
language plpgsql security definer set search_path=public as $$
begin
  -- Only when departure_time becomes set
  if (new.departure_time is not null) and (coalesce(old.departure_time, to_timestamp(0)) is distinct from new.departure_time) then
    perform public.m5_unbind_by_student(new.academy_id, new.student_id);
  end if;
  return new;
end; $$;

drop trigger if exists trg_m5_auto_unbind_on_departure on public.attendance_records;
create trigger trg_m5_auto_unbind_on_departure
after update on public.attendance_records
for each row execute function public._m5_auto_unbind_on_departure();





