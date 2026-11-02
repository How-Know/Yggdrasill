-- 심사 승인 본문과 동일하게 맞춤 (워커가 #{...} 치환)
update public.academy_alimtalk_settings
set makeup_message_template = $msg$#{학생명} 학생의 #{원래수업일시} 수업을 #{보강수업일시}에 보강하게 되어 안내드립니다. (방긋)

사유: #{변경사유}$msg$
where true;
