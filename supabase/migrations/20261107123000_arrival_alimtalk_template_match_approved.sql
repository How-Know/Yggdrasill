-- 등원 알림톡 본문을 2026-11-06 승인본과 맞춘다.
-- 차이: "지도하겠습니다." 뒤 공백, 마지막 이모지(😊 → 😄, 앞 공백 없음).

update public.academy_alimtalk_settings
set arrival_message_template = $arrival$#{학생명} 학생이 #{등원시간}에 등원하였습니다.

오늘도 열심히 공부할 수 있도록 지도하겠습니다. 
감사합니다.😄$arrival$
where arrival_template_code = 'bizp_2026103117011466187265646';
