-- Add set_id to attendance_records to track originating student_time_block set
ALTER TABLE public.attendance_records
ADD COLUMN IF NOT EXISTS set_id TEXT;

