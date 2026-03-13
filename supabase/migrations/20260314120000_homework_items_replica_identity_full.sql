-- Enable REPLICA IDENTITY FULL on homework_items so that Supabase Realtime
-- UPDATE events include all columns in newRecord (not just the primary key).
-- Without this, the Flutter app's realtime callback receives incomplete rows
-- and silently drops updates (student_id is empty → early return).

ALTER TABLE public.homework_items REPLICA IDENTITY FULL;
