-- 20260227120000: homework_assignments repeat/split metadata

alter table public.homework_assignments
  add column if not exists repeat_index integer not null default 1,
  add column if not exists split_parts integer not null default 1,
  add column if not exists split_round integer not null default 1;

update public.homework_assignments
   set repeat_index = coalesce(repeat_index, 1),
       split_parts = case
         when split_parts is null or split_parts < 1 then 1
         else split_parts
       end,
       split_round = case
         when split_round is null or split_round < 1 then 1
         when split_parts is null or split_parts < 1 then 1
         when split_round > split_parts then split_parts
         else split_round
       end
 where repeat_index is null
    or split_parts is null
    or split_parts < 1
    or split_round is null
    or split_round < 1
    or split_round > split_parts;

