-- Student delete cascade: index the remaining FK columns that had no usable index.
--
-- ON DELETE CASCADE / SET NULL looks up child rows by the FK column alone.
-- Indexes led by academy_id, or partial indexes with an unrelated predicate
-- (e.g. `where ended_at is null`), cannot serve that lookup, so every deleted
-- parent row scanned the whole child table. Measured on a real student delete
-- (rolled back): learning_attempts.exposure_id alone cost 39s of 59s and
-- student_problem_rounds.homework_item_problem_id another 11s.
--
-- Columns that already have a `where col is not null` index are skipped:
-- the planner can use those for `col = $1`.

-- learning records
create index if not exists idx_learning_attempts_exposure_id_fk
  on public.learning_attempts (exposure_id) where exposure_id is not null;
create index if not exists idx_student_problem_rounds_hw_problem_id_fk
  on public.student_problem_rounds (homework_item_problem_id) where homework_item_problem_id is not null;
create index if not exists idx_learning_sessions_flow_id_fk
  on public.learning_sessions (flow_id) where flow_id is not null;
create index if not exists idx_learning_sessions_homework_group_id_fk
  on public.learning_sessions (homework_group_id) where homework_group_id is not null;
create index if not exists idx_learning_sessions_homework_item_id_fk
  on public.learning_sessions (homework_item_id) where homework_item_id is not null;

-- homework
create index if not exists idx_homework_group_items_group_id_fk
  on public.homework_group_items (group_id);
create index if not exists idx_homework_group_items_homework_item_id_fk
  on public.homework_group_items (homework_item_id);
create index if not exists idx_homework_group_runtime_group_id_fk
  on public.homework_group_runtime (group_id);
create index if not exists idx_homework_group_transition_requests_group_id_fk
  on public.homework_group_transition_requests (group_id) where group_id is not null;
create index if not exists idx_homework_groups_source_homework_item_id_fk
  on public.homework_groups (source_homework_item_id) where source_homework_item_id is not null;
create index if not exists idx_homework_items_test_origin_flow_id_fk
  on public.homework_items (test_origin_flow_id) where test_origin_flow_id is not null;
create index if not exists idx_homework_assignments_carry_over_from_id_fk
  on public.homework_assignments (carry_over_from_id) where carry_over_from_id is not null;
create index if not exists idx_homework_assignment_checks_homework_item_id_fk
  on public.homework_assignment_checks (homework_item_id) where homework_item_id is not null;
create index if not exists idx_homework_session_plan_items_assignment_id_fk
  on public.homework_session_plan_items (assignment_id) where assignment_id is not null;
create index if not exists idx_homework_session_plan_items_carried_from_id_fk
  on public.homework_session_plan_items (carried_from_plan_item_id) where carried_from_plan_item_id is not null;
create index if not exists idx_homework_session_plan_items_group_id_fk
  on public.homework_session_plan_items (group_id) where group_id is not null;
create index if not exists idx_homework_session_plan_items_homework_item_id_fk
  on public.homework_session_plan_items (homework_item_id) where homework_item_id is not null;
create index if not exists idx_homework_study_intervals_item_id_fk
  on public.homework_study_intervals (item_id);
create index if not exists idx_homework_test_grading_attempt_items_hw_item_id_fk
  on public.homework_test_grading_attempt_items (homework_item_id) where homework_item_id is not null;
create index if not exists idx_homework_test_grading_attempts_hw_item_id_fk
  on public.homework_test_grading_attempts (homework_item_id) where homework_item_id is not null;
create index if not exists idx_pb_question_issue_reports_homework_item_id_fk
  on public.pb_question_issue_reports (homework_item_id) where homework_item_id is not null;

-- lessons, notifications, points, textbooks
create index if not exists idx_lesson_batch_sessions_replaced_with_id_fk
  on public.lesson_batch_sessions (replaced_with_session_id) where replaced_with_session_id is not null;
create index if not exists idx_lesson_occurrences_snapshot_id_fk
  on public.lesson_occurrences (snapshot_id) where snapshot_id is not null;
create index if not exists idx_attendance_notification_logs_queue_id_fk
  on public.attendance_notification_logs (queue_id) where queue_id is not null;
create index if not exists idx_makeup_notification_logs_queue_id_fk
  on public.makeup_notification_logs (queue_id) where queue_id is not null;
create index if not exists idx_student_charge_points_occurrence_id_fk
  on public.student_charge_points (charge_point_occurrence_id) where charge_point_occurrence_id is not null;
create index if not exists idx_student_handwriting_samples_report_id_fk
  on public.student_handwriting_samples (report_id) where report_id is not null;
create index if not exists idx_student_point_ledger_reverses_id_fk
  on public.student_point_ledger (reverses_id) where reverses_id is not null;
create index if not exists idx_student_textbook_link_preferences_flow_id_fk
  on public.student_textbook_link_preferences (flow_id) where flow_id is not null;
