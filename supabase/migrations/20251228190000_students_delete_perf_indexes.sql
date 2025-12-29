-- Speed up deletes of students (ON DELETE CASCADE fan-out)
-- Without a student_id index on referencing tables, deleting a student can trigger
-- full-table scans and hit statement_timeout (57014) on PostgREST/Supabase.

create index if not exists idx_attendance_records_student_id
  on public.attendance_records(student_id);

create index if not exists idx_payment_records_student_id
  on public.payment_records(student_id);

create index if not exists idx_session_overrides_student_id
  on public.session_overrides(student_id);

create index if not exists idx_homework_items_student_id
  on public.homework_items(student_id);

create index if not exists idx_lesson_snapshot_headers_student_id
  on public.lesson_snapshot_headers(student_id);

create index if not exists idx_lesson_batch_headers_student_id
  on public.lesson_batch_headers(student_id);

create index if not exists idx_lesson_batch_sessions_student_id
  on public.lesson_batch_sessions(student_id);

-- Secondary FK fan-out that can also slow down cascading deletes
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


