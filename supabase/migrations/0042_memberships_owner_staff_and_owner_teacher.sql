-- 0042: Restrict memberships.role to {owner,staff}, auto-create owner teacher, protect owner teacher delete, unique email per academy

-- 1) Backfill: admin -> staff (idempotent)
update public.memberships set role = 'staff' where role = 'admin';

-- 2) Enforce role set {owner,staff} with a named CHECK constraint (idempotent)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.memberships'::regclass
      and conname = 'chk_memberships_role_owner_staff'
  ) then
    alter table public.memberships
      add constraint chk_memberships_role_owner_staff
      check (role in ('owner','staff'));
  end if;
end$$;

-- 3) Unique email per academy for teachers (case-insensitive), allow NULLs
create unique index if not exists uq_teachers_email_per_academy
  on public.teachers(academy_id, lower(email)) where email is not null;

-- 4) Auto-create owner teacher on academy insert
create or replace function public.ensure_owner_teacher()
returns trigger
language plpgsql
security definer
set search_path = public as $$
declare
  v_email text;
  v_name text;
begin
  select email into v_email from auth.users where id = new.owner_user_id;
  if v_email is null then v_email := ''; end if;
  v_name := split_part(v_email, '@', 1);
  if v_name is null or length(v_name) = 0 then v_name := '관리자'; end if;

  -- Insert initial owner teacher card; role=0 (placeholder), UI will render label as '관리자' for owner
  insert into public.teachers(academy_id, user_id, email, name, role, description, display_order)
  values (new.id, new.owner_user_id, nullif(v_email, ''), v_name, 0, '', 0)
  on conflict do nothing;

  return new;
end$$;

drop trigger if exists trg_academies_owner_teacher on public.academies;
create trigger trg_academies_owner_teacher
after insert on public.academies
for each row execute function public.ensure_owner_teacher();

-- 5) Prevent deletion of the owner teacher row
create or replace function public.prevent_owner_teacher_delete()
returns trigger
language plpgsql
security definer
set search_path = public as $$
begin
  if exists (
    select 1 from public.academies a
     where a.id = old.academy_id and a.owner_user_id = old.user_id
  ) then
    raise exception 'cannot delete owner teacher';
  end if;
  return old;
end$$;

drop trigger if exists trg_teachers_prevent_owner_delete on public.teachers;
create trigger trg_teachers_prevent_owner_delete
before delete on public.teachers
for each row execute function public.prevent_owner_teacher_delete();




