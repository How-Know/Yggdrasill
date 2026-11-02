-- 보강 알림톡: 비즈 심사 템플릿 코드 + 기본 본문 + 발송 ON
-- Supabase SQL Editor에서 실행하거나: supabase db query --linked -f supabase/scripts/apply_makeup_alimtalk_template.sql
--
-- 학원이 여러 개이고 일부만 켜려면 아래 UPDATE 끝에 조건 추가:
--   AND academy_id = '00000000-0000-0000-0000-000000000000'::uuid

update public.academy_alimtalk_settings
set
  makeup_template_code = 'bizp_2026103117181166187439334',
  makeup_message_template = $msg$#{학생명} 학생의 #{원래수업일시} 수업을 #{보강수업일시}에 보강하게 되어 안내드립니다. (방긋)

사유: #{변경사유}$msg$,
  makeup_alimtalk_enabled = true
where true;
