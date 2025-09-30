-- 0022: Fix kakao_reservations audit trigger error (missing created_by)

alter table if exists public.kakao_reservations
  add column if not exists created_by uuid;

-- RLS/trigger are already defined in 0015; this file just adds the column
-- so that public._set_audit_fields() can safely set created_by on INSERT/UPDATE.






