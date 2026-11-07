-- 홈페이지 공지. 지금은 휴강만 올린다.
-- 학부모에게 보이는 목록은 오늘 이후만이고, 지난 공지는 학습앱에서만 남는다.

create table public.academy_notices (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies (id) on delete cascade,
  kind text not null default 'closure' check (kind = 'closure'),
  closure_date date not null,
  audience text not null default '전체' check (char_length(audience) between 1 and 40),
  note text not null default '' check (char_length(note) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index academy_notices_academy_date_idx
  on public.academy_notices (academy_id, closure_date);

alter table public.academy_notices enable row level security;

revoke all on table public.academy_notices from public, anon, authenticated;
grant select, insert, update, delete on table public.academy_notices to authenticated;

create policy academy_notices_select
  on public.academy_notices
  for select to authenticated
  using (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = academy_notices.academy_id
    )
  );

create policy academy_notices_insert
  on public.academy_notices
  for insert to authenticated
  with check (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = academy_notices.academy_id
    )
  );

create policy academy_notices_update
  on public.academy_notices
  for update to authenticated
  using (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = academy_notices.academy_id
    )
  )
  with check (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = academy_notices.academy_id
    )
  );

create policy academy_notices_delete
  on public.academy_notices
  for delete to authenticated
  using (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = academy_notices.academy_id
    )
  );
