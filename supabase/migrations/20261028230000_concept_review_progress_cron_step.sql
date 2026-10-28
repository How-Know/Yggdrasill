-- 1분 예약은 이미 트랜잭션 안에서 명령을 실행한다.
-- 그 안에서 프로시저가 commit 하면 구간 계산이 롤백되므로, 예약은 중간 저장 없는 한 구간만 호출한다.
-- 호출이 끝나면 예약이 그 구간을 저장하고, 다음 분이 이어서 한다.
-- Think가 한 요청에 판단하는 50개와는 다른 수다. 여기서 20개는 진행률 저장 구간이다.

do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'concept-review-progress') then
      perform cron.unschedule('concept-review-progress');
    end if;
    perform cron.schedule(
      'concept-review-progress',
      '* * * * *',
      'select public.concept_review_progress_step(null, 20)'
    );
  end if;
exception when others then
  raise notice 'concept_review_progress cron not scheduled: %', sqlerrm;
end
$cron$;
