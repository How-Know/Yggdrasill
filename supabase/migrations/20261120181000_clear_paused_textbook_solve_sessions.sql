-- 교재 카드에 남아 있는 바로풀기 중단 칩을 비운다.
-- 진행 중인 숙제 세션은 entry_mode 가 없으므로 건드리지 않는다.
update public.learning_sessions
set status = 'completed',
    ended_at = coalesce(ended_at, now()),
    paused_at = null,
    updated_at = now()
where entry_mode = 'solve'
  and status = 'paused';
