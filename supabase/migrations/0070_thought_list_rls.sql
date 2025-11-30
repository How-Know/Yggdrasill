-- RLS enable + policies for thought_folder / thought_card

-- Enable Row Level Security (idempotent)
alter table if exists public.thought_folder enable row level security;
alter table if exists public.thought_card   enable row level security;

-- Drop existing policies if present (idempotent)
drop policy if exists thought_folder_select on public.thought_folder;
drop policy if exists thought_folder_insert on public.thought_folder;
drop policy if exists thought_folder_update on public.thought_folder;
drop policy if exists thought_folder_delete on public.thought_folder;

drop policy if exists thought_card_select on public.thought_card;
drop policy if exists thought_card_insert on public.thought_card;
drop policy if exists thought_card_update on public.thought_card;
drop policy if exists thought_card_delete on public.thought_card;

-- Allow authenticated users full access (temporary broad policy to match current app behavior)
create policy thought_folder_select on public.thought_folder
  for select to authenticated using (true);
create policy thought_folder_insert on public.thought_folder
  for insert to authenticated with check (true);
create policy thought_folder_update on public.thought_folder
  for update to authenticated using (true);
create policy thought_folder_delete on public.thought_folder
  for delete to authenticated using (true);

create policy thought_card_select on public.thought_card
  for select to authenticated using (true);
create policy thought_card_insert on public.thought_card
  for insert to authenticated with check (true);
create policy thought_card_update on public.thought_card
  for update to authenticated using (true);
create policy thought_card_delete on public.thought_card
  for delete to authenticated using (true);

-- NOTE: 장기적으로 다중 테넌트 격리가 필요하면 academy_id 등 스코프 컬럼을 추가하고
-- memberships 기반 정책으로 좁힐 것을 권장합니다.

























