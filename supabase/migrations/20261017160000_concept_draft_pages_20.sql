-- 개념 초안 한 번에 정리하는 쪽 수 한도를 12쪽에서 20쪽으로 올린다(운영자 결정 2026-10-17: 12쪽 넘는 소단원도 한 번에 만든다).
-- Edge 함수 concept_draft_organize 의 MAX_PAGES, 매니저 kConceptDraftMaxPages 와 같은 값이다.
-- 처음 만든 제약은 이름 없이 열에 달려 있어서, 정의로 찾아 지운 뒤 이름을 붙여 다시 단다. 기존 행은 모두 12쪽 이하라 그대로 맞는다.

do $migration$
declare
  v_name text;
begin
  for v_name in
    select c.conname
      from pg_constraint c
     where c.conrelid = 'public.concept_drafts'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) ilike '%cardinality(pages)%'
  loop
    execute format('alter table public.concept_drafts drop constraint %I', v_name);
  end loop;
end;
$migration$;

alter table public.concept_drafts
  add constraint concept_drafts_pages_check check (cardinality(pages) between 1 and 20);
