-- 보강 알림톡: 비즈 심사 템플릿 코드 + 기본 본문 + 발송 ON
-- Supabase SQL Editor에서 실행하거나: supabase db query --linked -f supabase/scripts/apply_makeup_alimtalk_template.sql
--
-- 학원이 여러 개이고 일부만 켜려면 아래 UPDATE 끝에 조건 추가:
--   AND academy_id = '00000000-0000-0000-0000-000000000000'::uuid

update public.academy_alimtalk_settings
set
  makeup_template_code = 'bizp_2026040916544225806394927',
  makeup_message_template = coalesce(
    nullif(trim(makeup_message_template), ''),
    '[#{학원명}] #{학생명} 보강 예약: 원래 #{원래수업일시} → #{보강수업일시} (#{변경사유})'
  ),
  makeup_alimtalk_enabled = true
where true;
