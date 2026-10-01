-- Student delete runs ON DELETE CASCADE / SET NULL by student_id alone.
-- An index that starts with academy_id, or a partial index, cannot serve that
-- lookup, so PostgreSQL scans the whole table and hits statement_timeout (57014).

create index if not exists idx_learning_sessions_student_id_fk
  on public.learning_sessions (student_id);

create index if not exists idx_learning_exposures_student_id_fk
  on public.learning_exposures (student_id);

create index if not exists idx_learning_attempts_student_id_fk
  on public.learning_attempts (student_id);

create index if not exists idx_learning_range_timings_student_id_fk
  on public.learning_range_timings (student_id);

create index if not exists idx_homework_study_intervals_student_id_fk
  on public.homework_study_intervals (student_id);

create index if not exists idx_homework_item_problems_student_id_fk
  on public.homework_item_problems (student_id);

create index if not exists idx_homework_item_pages_student_id_fk
  on public.homework_item_pages (student_id);

create index if not exists idx_homework_item_units_student_id_fk
  on public.homework_item_units (student_id);

create index if not exists idx_homework_groups_student_id_fk
  on public.homework_groups (student_id);

create index if not exists idx_homework_group_items_student_id_fk
  on public.homework_group_items (student_id);

create index if not exists idx_homework_group_runtime_student_id_fk
  on public.homework_group_runtime (student_id);

create index if not exists idx_homework_test_grading_attempts_student_id_fk
  on public.homework_test_grading_attempts (student_id);

create index if not exists idx_homework_test_grading_attempt_items_student_id_fk
  on public.homework_test_grading_attempt_items (student_id);

create index if not exists idx_homework_session_plan_items_student_id_fk
  on public.homework_session_plan_items (student_id);

create index if not exists idx_homework_group_transition_requests_student_id_fk
  on public.homework_group_transition_requests (student_id);

create index if not exists idx_makeup_notification_queue_student_id_fk
  on public.makeup_notification_queue (student_id);

create index if not exists idx_makeup_notification_logs_student_id_fk
  on public.makeup_notification_logs (student_id);

create index if not exists idx_attendance_notification_queue_student_id_fk
  on public.attendance_notification_queue (student_id);

create index if not exists idx_attendance_notification_logs_student_id_fk
  on public.attendance_notification_logs (student_id);

create index if not exists idx_student_pause_periods_student_id_fk
  on public.student_pause_periods (student_id);

create index if not exists idx_student_charge_points_student_id_fk
  on public.student_charge_points (student_id);

create index if not exists idx_student_class_session_snapshots_student_id_fk
  on public.student_class_session_snapshots (student_id);

create index if not exists idx_m5_student_question_requests_student_id_fk
  on public.m5_student_question_requests (student_id);

create index if not exists idx_student_score_cache_student_id_fk
  on public.student_score_cache (student_id);

create index if not exists idx_student_point_ledger_student_id_fk
  on public.student_point_ledger (student_id);

create index if not exists idx_student_point_balances_student_id_fk
  on public.student_point_balances (student_id);

create index if not exists idx_student_textbook_link_preferences_student_id_fk
  on public.student_textbook_link_preferences (student_id);

create index if not exists idx_student_signup_codes_student_id_fk
  on public.student_signup_codes (student_id);

create index if not exists idx_watch_push_events_student_id_fk
  on public.watch_push_events (student_id);

create index if not exists idx_pb_question_issue_reports_student_id_fk
  on public.pb_question_issue_reports (student_id);

create index if not exists idx_student_grading_equiv_logs_student_id_fk
  on public.student_grading_equiv_logs (student_id);
