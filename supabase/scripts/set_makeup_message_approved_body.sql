-- 심사 승인 본문과 동일하게 맞춤 (워커가 #{...} 치환)
update public.academy_alimtalk_settings
set makeup_message_template = $msg$[#{학원명}] 보강 예약 안내

안녕하세요, #{학원명}입니다.

#{학생명} 학생의 #{원래수업일시} 수업을 #{보강수업일시}에 보강하게 되어 안내드립니다. (방긋)

사유: #{변경사유}

※ 추가 변경 시 학원으로 연락 부탁드립니다.$msg$
where true;
