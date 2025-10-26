-- Fix _set_audit_fields to preserve updated_by when explicitly set
-- This allows homework RPCs to set updated_by to student_id from M5 devices

create or replace function public._set_audit_fields()
returns trigger
language plpgsql
security definer as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_at := coalesce(new.updated_at, now());
    new.updated_by := coalesce(new.updated_by, auth.uid());
    new.version := coalesce(new.version, 1);
  elsif tg_op = 'UPDATE' then
    new.updated_at := now();
    -- Only set updated_by if not already set by the caller (e.g. RPC with p_updated_by)
    new.updated_by := coalesce(new.updated_by, auth.uid());
    new.version := coalesce(old.version, 1) + 1;
  end if;
  return new;
end$$;













