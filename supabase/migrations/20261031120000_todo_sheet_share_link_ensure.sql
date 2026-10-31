-- 하원 직후 학부모 링크를 만들기 위한 직원용 함수.
-- 같은 저장본에는 처음 만든 토큰을 다시 돌려준다.

create or replace function public.staff_ensure_todo_sheet_share_link_v1(
  p_snapshot_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_snapshot public.student_class_session_todo_sheet_snapshots%rowtype;
  v_token text;
begin
  select *
    into v_snapshot
    from public.student_class_session_todo_sheet_snapshots s
   where s.id = p_snapshot_id;

  if not found then
    raise exception 'TODO_SHEET_SNAPSHOT_NOT_FOUND';
  end if;

  if not exists (
    select 1
      from public.memberships m
     where m.academy_id = v_snapshot.academy_id
       and m.user_id = auth.uid()
  ) then
    raise exception 'FORBIDDEN';
  end if;

  select l.token
    into v_token
    from public.todo_sheet_share_links l
   where l.snapshot_id = v_snapshot.id
   order by l.created_at asc
   limit 1;

  if v_token is not null then
    return v_token;
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '')
    || replace(gen_random_uuid()::text, '-', '');

  insert into public.todo_sheet_share_links (
    token,
    academy_id,
    student_id,
    snapshot_id
  ) values (
    v_token,
    v_snapshot.academy_id,
    v_snapshot.student_id,
    v_snapshot.id
  );

  return v_token;
end;
$$;

revoke all on function public.staff_ensure_todo_sheet_share_link_v1(uuid)
  from public, anon;
grant execute on function public.staff_ensure_todo_sheet_share_link_v1(uuid)
  to authenticated;
