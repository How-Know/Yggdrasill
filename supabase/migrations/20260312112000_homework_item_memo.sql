-- 하위 과제용 지시사항 메모 컬럼
alter table public.homework_items
add column if not exists memo text;

comment on column public.homework_items.memo is
'과제 지시사항 메모(예: 홀수 번호만 풀이)';
