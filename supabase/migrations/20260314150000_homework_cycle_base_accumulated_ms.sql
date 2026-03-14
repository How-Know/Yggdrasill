-- Keep per-cycle progress baseline while preserving total accumulated time.
-- Cycle progress should reset only after submit/confirm cycle returns to waiting.

alter table public.homework_items
  add column if not exists cycle_base_accumulated_ms bigint not null default 0;

-- Backfill current waiting items so next run starts from cycle progress 0.
update public.homework_items
   set cycle_base_accumulated_ms = coalesce(accumulated_ms, 0)
 where coalesce(phase, 1) = 1
   and coalesce(cycle_base_accumulated_ms, 0) = 0;

create or replace function public._sync_homework_cycle_base_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.cycle_base_accumulated_ms is null then
      if coalesce(new.phase, 1) = 1 then
        new.cycle_base_accumulated_ms := coalesce(new.accumulated_ms, 0);
      else
        new.cycle_base_accumulated_ms := 0;
      end if;
    end if;
    return new;
  end if;

  new.cycle_base_accumulated_ms := coalesce(
    new.cycle_base_accumulated_ms,
    old.cycle_base_accumulated_ms,
    0
  );

  -- Reset cycle baseline only when submit/confirm cycle returns to waiting.
  if coalesce(new.phase, 1) = 1 and coalesce(old.phase, 1) in (3, 4) then
    new.cycle_base_accumulated_ms := coalesce(new.accumulated_ms, 0);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_homework_items_cycle_base_sync on public.homework_items;
create trigger trg_homework_items_cycle_base_sync
before insert or update on public.homework_items
for each row execute function public._sync_homework_cycle_base_before_write();
