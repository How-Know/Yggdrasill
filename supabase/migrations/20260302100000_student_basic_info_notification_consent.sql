ALTER TABLE student_basic_info
  ADD COLUMN IF NOT EXISTS notification_consent BOOLEAN DEFAULT FALSE;
