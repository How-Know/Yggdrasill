-- 2026-11-02 승인된 강조표기형 알림톡.
-- 하원 안내 v2는 알림장 미동의, 하원 안내 (알림장)은 동의 학생용이다.

alter table public.academy_alimtalk_settings
  add column if not exists departure_sheet_template_code text,
  add column if not exists departure_sheet_message_template text;

update public.academy_alimtalk_settings
set
  arrival_template_code = 'bizp_2026103117011466187265646',
  arrival_message_template = $arrival$#{학생명} 학생이 #{등원시간}에 등원하였습니다.

오늘도 열심히 공부할 수 있도록 지도하겠습니다.
감사합니다. 😊$arrival$,
  departure_template_code = 'bizp_2026103117143866187543653',
  departure_message_template = $departure$#{학생명} 학생이 #{하원시간}에 하원하였습니다.

오늘도 좋은 하루 되세요.
감사합니다. 😊$departure$,
  departure_sheet_template_code = 'bizp_2026103123220902342367920',
  departure_sheet_message_template = $sheet$#{학생명} 학생이 #{하원시간}에 하원하였습니다.

오늘도 좋은 하루 되세요.
감사합니다. 😊$sheet$,
  late_template_code = 'bizp_2026103117170166187129142',
  late_message_template = $late$#{학생명} 학생이 #{수업시작시간}에 수업이 예정되어 있으나, 아직 학원에 도착하지 않아 안내드립니다.

확인 부탁드리겠습니다.
감사합니다.$late$,
  makeup_template_code = 'bizp_2026103117181166187439334',
  makeup_message_template = $makeup$#{학생명} 학생의 #{원래수업일시} 수업을 #{보강수업일시}에 보강하게 되어 안내드립니다. (방긋)

사유: #{변경사유}$makeup$;
