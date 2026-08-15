-- learning_attempts의 시도 번호 기본값이 1이라 BEFORE INSERT 트리거가
-- 두 번째 시도에서도 번호를 재계산하지 못했다. 같은 세션·문항의 두 번째
-- 기록이 (session_id, crop_id, 1) 유니크 키와 충돌하므로, 모든 INSERT에서
-- 현재 최대값 + 1을 배정한다.
--
-- 동일 학생·문항의 동시 INSERT도 같은 번호를 고르지 않도록 transaction
-- advisory lock으로 직렬화한다.

create or replace function public._learning_fill_attempt_no()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_key text;
begin
  v_item_key := case
    when new.crop_id is not null then 'crop:' || new.crop_id::text
    else 'pb:' || coalesce(new.pb_question_uid::text, '')
  end;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'learning_attempt:' || new.student_id::text || ':' || v_item_key,
      0
    )
  );

  select coalesce(max(a.attempt_no), 0) + 1
    into new.attempt_no
  from public.learning_attempts a
  where a.student_id = new.student_id
    and a.result <> 'void'
    and (
      (new.crop_id is not null and a.crop_id = new.crop_id)
      or (new.crop_id is null and new.pb_question_uid is not null
          and a.pb_question_uid = new.pb_question_uid)
    );

  select coalesce(max(a.attempt_no_in_session), 0) + 1
    into new.attempt_no_in_session
  from public.learning_attempts a
  where a.session_id = new.session_id
    and (
      (new.crop_id is not null and a.crop_id = new.crop_id)
      or (new.crop_id is null and new.pb_question_uid is not null
          and a.pb_question_uid = new.pb_question_uid)
    );

  return new;
end;
$$;

comment on function public._learning_fill_attempt_no() is
  '학생·문항별 시도 번호와 세션 내 시도 번호를 동시성 안전하게 max+1로 채운다.';
