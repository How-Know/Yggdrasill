-- 0026: Expand homework_items.color to bigint to store full ARGB 32-bit values
-- Reason: Flutter Color.value can be up to 0xFFFFFFFF (4294967295), which exceeds INT4
-- Safe change: widen integer → bigint; existing values are preserved

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'homework_items'
      and column_name  = 'color'
      and data_type in ('integer','smallint')
  ) then
    alter table public.homework_items
      alter column color type bigint using color::bigint;
  end if;
end$$;

-- Optional: ensure constraint bounds are not present (none expected by default)
-- No RLS/policies/triggers impacted; only type widening



