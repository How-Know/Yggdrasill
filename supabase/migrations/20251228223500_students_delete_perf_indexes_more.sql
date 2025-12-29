-- Additional indexes for fast FK cascades / set null paths during student deletion.
-- NOTE: This is intentionally a *new* migration to avoid "applied migration edited" drift.

create index if not exists idx_session_overrides_student_id
  on public.session_overrides(student_id);

create index if not exists idx_homework_items_student_id
  on public.homework_items(student_id);

create index if not exists idx_session_overrides_original_attendance_id
  on public.session_overrides(original_attendance_id);

create index if not exists idx_session_overrides_replacement_attendance_id
  on public.session_overrides(replacement_attendance_id);

create index if not exists idx_lesson_batch_sessions_attendance_id
  on public.lesson_batch_sessions(attendance_id);

create index if not exists idx_attendance_records_batch_session_id
  on public.attendance_records(batch_session_id);

create index if not exists idx_attendance_records_snapshot_id
  on public.attendance_records(snapshot_id);

create index if not exists idx_lesson_batch_headers_snapshot_id
  on public.lesson_batch_headers(snapshot_id);

create index if not exists idx_lesson_batch_sessions_snapshot_id
  on public.lesson_batch_sessions(snapshot_id);




