-- Free-text reason for makeup / schedule change (알림톡 템플릿 변수 등)
alter table public.session_overrides
  add column if not exists change_reason text;
