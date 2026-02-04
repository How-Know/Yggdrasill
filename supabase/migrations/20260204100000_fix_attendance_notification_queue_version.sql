-- Fix: _set_audit_fields trigger expects a version column.
alter table public.attendance_notification_queue
  add column if not exists version integer not null default 1;
