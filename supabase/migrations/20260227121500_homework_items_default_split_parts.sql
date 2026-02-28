-- 20260227121500: homework_items default split metadata
alter table public.homework_items
  add column if not exists default_split_parts integer not null default 1;

update public.homework_items
   set default_split_parts = case
     when default_split_parts is null or default_split_parts < 1 then 1
     when default_split_parts > 4 then 4
     else default_split_parts
   end
 where default_split_parts is null
    or default_split_parts < 1
    or default_split_parts > 4;
