-- 홈페이지 상담 신청. 학부모 번호는 상담 연락용으로만 두고, 공개 조회는 없다.
-- 상담을 마친 뒤 1년이 지나면 학습앱이 목록을 열 때 지운다.

create table public.homepage_consultation_requests (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies (id) on delete cascade,
  phone text not null,
  available_time text not null,
  question text,
  consent_at timestamptz not null,
  status text not null default 'new'
    check (status in ('new', 'contacted', 'done')),
  contacted_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create index homepage_consultation_requests_academy_created_idx
  on public.homepage_consultation_requests (academy_id, created_at desc);

create index homepage_consultation_requests_phone_created_idx
  on public.homepage_consultation_requests (phone, created_at desc);

alter table public.homepage_consultation_requests enable row level security;

revoke all on table public.homepage_consultation_requests from public, anon, authenticated;
grant select, update, delete on table public.homepage_consultation_requests to authenticated;

create policy homepage_consultation_requests_select
  on public.homepage_consultation_requests
  for select to authenticated
  using (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = homepage_consultation_requests.academy_id
    )
  );

create policy homepage_consultation_requests_update
  on public.homepage_consultation_requests
  for update to authenticated
  using (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = homepage_consultation_requests.academy_id
    )
  )
  with check (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = homepage_consultation_requests.academy_id
    )
  );

create policy homepage_consultation_requests_delete
  on public.homepage_consultation_requests
  for delete to authenticated
  using (
    exists (
      select 1
        from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = homepage_consultation_requests.academy_id
    )
  );

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1
        from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'homepage_consultation_requests'
    ) then
      execute 'alter publication supabase_realtime add table public.homepage_consultation_requests';
    end if;
  end if;
end $$;

alter table public.homepage_consultation_requests replica identity full;
