-- Fix academy_notification_pause_dates audit trigger compatibility.
-- public._set_audit_fields() expects every audited table to have version.

alter table public.academy_notification_pause_dates
  add column if not exists version integer not null default 1;
-- Fix academy_notification_pause_dates audit trigger compatibility.
-- public._set_audit_fields() expects every audited table to have version.

alter table public.academy_notification_pause_dates
  add column if not exists version integer not null default 1;
