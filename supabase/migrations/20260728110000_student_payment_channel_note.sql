-- student_payment_info: 납부 채널(현금/이체/카드/앱) + 특이사항 메모
ALTER TABLE public.student_payment_info
  ADD COLUMN IF NOT EXISTS payment_channel text NOT NULL DEFAULT 'card',
  ADD COLUMN IF NOT EXISTS payment_note text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'student_payment_info_payment_channel_check'
  ) THEN
    ALTER TABLE public.student_payment_info
      ADD CONSTRAINT student_payment_info_payment_channel_check
      CHECK (payment_channel IN ('cash', 'transfer', 'card', 'app'));
  END IF;
END$$;
