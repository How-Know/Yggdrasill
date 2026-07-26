-- 20260726130000: 과제 문항 스냅샷에 출제 단계(원본/변형) 기록
--
-- 마이그레이션 교재 과제는 "원본 문항"으로 낼 수도 있고, 앞으로 만들 변형 문항
-- 으로 낼 수도 있다. 어떤 단계로 출제했는지는 문항 단위로만 의미가 있으므로
-- (같은 과제 안에서 원본/변형이 섞일 수 있다) homework_item_problems 에 둔다.
--
-- 현재는 'original' 만 실제 데이터가 존재한다. variant1~3 은 변형 문항 파이프
-- 라인이 생긴 뒤에 쓰인다.

alter table public.homework_item_problems
  add column if not exists source_stage text not null default 'original';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'homework_item_problems_source_stage_chk'
      and conrelid = 'public.homework_item_problems'::regclass
  ) then
    alter table public.homework_item_problems
      add constraint homework_item_problems_source_stage_chk
      check (source_stage in ('original', 'variant1', 'variant2', 'variant3'));
  end if;
end $$;

create index if not exists idx_homework_item_problems_stage
  on public.homework_item_problems (academy_id, source_stage)
  where source_stage <> 'original';

comment on column public.homework_item_problems.source_stage is
  '출제 단계. original=교재 원본 문항, variant1~3=변형 문항. '
  '과제 다이얼로그의 "단계" 선택이 여기에 기록된다.';
