-- Add display order to classes (local migration to keep class list order)
alter table public.classes
  add column if not exists order_index integer default 0;

-- Backfill: 이름 순으로 순서 매기기 (기존 null만 대상)
update public.classes c
set order_index = sub.ord
from (
  select id, row_number() over (order by name) - 1 as ord
  from public.classes
) sub
where c.id = sub.id
  and (c.order_index is null);

-- 새로운 레코드도 항상 값이 있도록 not null 설정
alter table public.classes
  alter column order_index set not null;

