-- 20261012100000: Think 부서별 트리·부서 넘기기 (운영자 결정 2026-10-12)
-- - 트리를 부서(총괄·교육·문제 풀이·개발) 네 칸으로 먼저 나눈다. 폴더마다 부서(department)를 두고, 하위 폴더는
--   상위 폴더의 부서를 따른다. 대화는 저장된 역할(think_role_id)이 부서다. 'product'는 화면 이름만 '문제 풀이'로 바뀌었다.
-- - 기존 최상위 폴더는 안의 대화가 가장 많이 속한 부서로 둔다. 가장 많은 부서가 둘 이상이거나 대화가 없으면 총괄.
--   대화의 역할은 자동으로 바꾸지 않는다(폴더와 역할이 다른 대화는 앱이 표시만 한다).
-- - 다른 부서로 옮기기(ai_tree_move_department, ai_conversation_move_department)는 옮긴 대화의 역할도 그 부서로 바꾼다.
--   앱이 먼저 확인 창을 띄운다. 역할 칩으로 역할을 바꿔 폴더 부서와 달라지면 그 대화는 새 부서의 미분류로 빠진다.
-- - handover_department: Think가 이 대화를 다른 부서가 맡자고 제안한다. 승인하면 같은 대화의 역할을 바꾸고
--   그 부서의 미분류로 옮긴다. 제안은 전용 RPC로만 만든다.
-- 설계: docs/architecture/ai-think-actions.md §10

-- ---------------------------------------------------------------------------
-- 1) 폴더 부서
-- ---------------------------------------------------------------------------
alter table public.ai_tree_nodes add column if not exists department text;

alter table public.ai_tree_nodes drop constraint if exists ai_tree_nodes_department_check;
alter table public.ai_tree_nodes add constraint ai_tree_nodes_department_check
  check (department is null or department in ('lead', 'education', 'product', 'engineering'));

-- 폴더가 아니면 부서가 없다. 하위 폴더는 상위 폴더의 부서를 따른다. 최상위 폴더는 정한 값(없으면 이전 값, 그것도 없으면 총괄).
create or replace function public.ai_tree_nodes_department_before()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_parent_dept text;
begin
  if new.kind <> 'folder' then
    new.department := null;
    return new;
  end if;
  if new.parent_id is not null then
    select department into v_parent_dept from public.ai_tree_nodes where id = new.parent_id;
    new.department := coalesce(v_parent_dept, new.department, 'lead');
  else
    new.department := coalesce(new.department, case when tg_op = 'UPDATE' then old.department end, 'lead');
  end if;
  return new;
end
$$;

drop trigger if exists trg_ai_tree_nodes_department_before on public.ai_tree_nodes;
create trigger trg_ai_tree_nodes_department_before
  before insert or update of parent_id, department, kind on public.ai_tree_nodes
  for each row execute function public.ai_tree_nodes_department_before();

-- 폴더의 부서가 바뀌면 하위 폴더도 따라 바뀐다(하위 폴더의 갱신이 다시 그 아래로 이어진다).
create or replace function public.ai_tree_nodes_department_after()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.kind = 'folder' and new.department is distinct from old.department then
    update public.ai_tree_nodes
       set department = new.department
     where parent_id = new.id
       and kind = 'folder'
       and department is distinct from new.department;
  end if;
  return null;
end
$$;

drop trigger if exists trg_ai_tree_nodes_department_after on public.ai_tree_nodes;
create trigger trg_ai_tree_nodes_department_after
  after update of department on public.ai_tree_nodes
  for each row execute function public.ai_tree_nodes_department_after();

-- 기존 최상위 폴더: 안(하위 폴더 포함)의 대화가 가장 많이 속한 부서. 동률이거나 대화가 없으면 총괄.
with recursive sub as (
  select id as root_id, id
    from public.ai_tree_nodes
   where kind = 'folder' and parent_id is null
  union all
  select s.root_id, n.id
    from public.ai_tree_nodes n
    join sub s on n.parent_id = s.id
), counts as (
  select s.root_id, c.think_role_id as dept, count(*) as cnt
    from sub s
    join public.ai_tree_nodes n on n.id = s.id and n.kind = 'conversation'
    join public.ai_conversations c on c.id = n.conversation_id
   group by s.root_id, c.think_role_id
), ranked as (
  select root_id, dept, rank() over (partition by root_id order by cnt desc) as rk
    from counts
), top as (
  select root_id, case when count(*) = 1 then min(dept) else 'lead' end as dept
    from ranked
   where rk = 1
   group by root_id
)
update public.ai_tree_nodes n
   set department = coalesce(t.dept, 'lead')
  from public.ai_tree_nodes r
  left join top t on t.root_id = r.id
 where r.kind = 'folder'
   and r.parent_id is null
   and n.id = r.id
   and n.department is distinct from coalesce(t.dept, 'lead');

-- 남은 폴더(부모가 이미 같은 부서라 갱신되지 않은 하위 폴더 등)는 상위 폴더를 따라 채운다.
with recursive walk as (
  select id, department
    from public.ai_tree_nodes
   where kind = 'folder' and parent_id is null
  union all
  select n.id, w.department
    from public.ai_tree_nodes n
    join walk w on n.parent_id = w.id
   where n.kind = 'folder'
)
update public.ai_tree_nodes n
   set department = w.department
  from walk w
 where n.id = w.id
   and n.department is distinct from w.department;

update public.ai_tree_nodes set department = 'lead' where kind = 'folder' and department is null;

alter table public.ai_tree_nodes drop constraint if exists ai_tree_nodes_department_shape;
alter table public.ai_tree_nodes add constraint ai_tree_nodes_department_shape
  check ((kind = 'folder') = (department is not null));

-- ---------------------------------------------------------------------------
-- 2) 내부 도우미
-- ---------------------------------------------------------------------------
-- 대화 노드가 놓인 폴더의 부서. 최상위이거나 트리에 없으면 null(대화 역할이 곧 부서).
create or replace function public.ai_tree_conversation_section(p_conversation_id uuid)
returns text
language sql
stable
set search_path = public
as $$
  select f.department
    from public.ai_tree_nodes n
    join public.ai_tree_nodes f on f.id = n.parent_id
   where n.kind = 'conversation'
     and n.conversation_id = p_conversation_id
$$;

-- 대화를 다른 부서로 옮긴다: 역할을 바꾸고(같은 부서 추가 참조는 뺀다), p_unfile이면 트리에서 빼서 그 부서의 미분류로,
-- 아니면 폴더 부서와 달라졌을 때만 뺀다.
create or replace function public.ai_conversation_change_department(p_conversation_id uuid, p_role text, p_unfile boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conv public.ai_conversations;
  v_section text;
  v_unfiled boolean := false;
begin
  if p_role is null or p_role not in ('lead', 'education', 'product', 'engineering') then
    raise exception 'think_role_invalid' using errcode = '22023';
  end if;
  select * into v_conv from public.ai_conversations where id = p_conversation_id for update;
  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if v_conv.think_role_id is distinct from p_role then
    update public.ai_conversations
       set think_role_id = p_role,
           extra_ref_departments = array_remove(extra_ref_departments, p_role)
     where id = p_conversation_id;
  end if;
  v_section := public.ai_tree_conversation_section(p_conversation_id);
  if p_unfile or (v_section is not null and v_section <> p_role) then
    delete from public.ai_tree_nodes where kind = 'conversation' and conversation_id = p_conversation_id;
    v_unfiled := found;
  end if;
  return jsonb_build_object(
    'conversation_id', p_conversation_id,
    'from_department', v_conv.think_role_id,
    'to_department', p_role,
    'changed', v_conv.think_role_id is distinct from p_role,
    'unfiled', v_unfiled
  );
end
$$;

-- ---------------------------------------------------------------------------
-- 3) 역할 저장 (20261010160000 정의 + 폴더 부서와 달라지면 미분류로)
-- ---------------------------------------------------------------------------
create or replace function public.ai_conversation_set_think_role(
  p_conversation_id uuid,
  p_think_role_id text,
  p_extra_ref_departments text[] default '{}'::text[],
  p_role_profile_version text default null
)
returns public.ai_conversations
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row public.ai_conversations;
  v_refs text[] := coalesce(p_extra_ref_departments, '{}'::text[]);
  v_section text;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_think_role_id not in ('lead', 'education', 'product', 'engineering') then
    raise exception 'think_role_invalid' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_refs) r where r not in ('education', 'product', 'engineering')) then
    raise exception 'extra_ref_invalid' using errcode = '22023';
  end if;
  update public.ai_conversations
     set think_role_id = p_think_role_id,
         extra_ref_departments = v_refs,
         role_profile_version = coalesce(nullif(btrim(p_role_profile_version), ''), role_profile_version)
   where id = p_conversation_id
  returning * into v_row;
  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  v_section := public.ai_tree_conversation_section(p_conversation_id);
  if v_section is not null and v_section <> p_think_role_id then
    delete from public.ai_tree_nodes where kind = 'conversation' and conversation_id = p_conversation_id;
  end if;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- 4) 부서 간 옮기기
-- ---------------------------------------------------------------------------
-- 노드(또는 아직 트리에 없는 대화)를 p_parent_id 아래 p_index 자리로 옮긴다. 최상위면 p_department 칸으로.
-- 옮긴 대화(폴더면 그 안의 모든 대화) 중 부서가 다른 대화는 역할을 그 부서로 바꾼다. 반환: {node_id, department, roles_changed}
create or replace function public.ai_tree_move_department(
  p_node_id uuid,
  p_conversation_id uuid,
  p_parent_id uuid,
  p_index integer,
  p_department text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dept text;
  v_node public.ai_tree_nodes;
  v_changed integer := 0;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_parent_id is not null then
    select department into v_dept from public.ai_tree_nodes where id = p_parent_id and kind = 'folder';
    if not found then
      raise exception 'tree_parent_not_folder' using errcode = '22023';
    end if;
  else
    v_dept := p_department;
  end if;
  if v_dept is null or v_dept not in ('lead', 'education', 'product', 'engineering') then
    raise exception 'tree_department_invalid' using errcode = '22023';
  end if;

  if p_node_id is not null then
    select * into v_node from public.ai_tree_nodes where id = p_node_id for update;
    if not found then
      raise exception 'tree_node_not_found' using errcode = 'P0002';
    end if;
  elsif p_conversation_id is not null then
    if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
      raise exception 'conversation_not_found' using errcode = 'P0002';
    end if;
    select * into v_node from public.ai_tree_nodes where kind = 'conversation' and conversation_id = p_conversation_id;
    if not found then
      insert into public.ai_tree_nodes (kind, conversation_id, parent_id, sort_order)
      values ('conversation', p_conversation_id, p_parent_id, 2147483647)
      returning * into v_node;
    end if;
  else
    raise exception 'tree_node_not_found' using errcode = 'P0002';
  end if;

  perform public.ai_tree_move(v_node.id, p_parent_id, p_index);
  -- 최상위로 옮긴 폴더는 옮긴 뒤에 부서를 정한다(옮기기 전에는 상위 폴더 부서를 따르므로).
  if v_node.kind = 'folder' and p_parent_id is null then
    update public.ai_tree_nodes set department = v_dept where id = v_node.id and department is distinct from v_dept;
  end if;

  with recursive sub as (
    select id from public.ai_tree_nodes where id = v_node.id
    union all
    select n.id from public.ai_tree_nodes n join sub s on n.parent_id = s.id
  )
  update public.ai_conversations c
     set think_role_id = v_dept,
         extra_ref_departments = array_remove(c.extra_ref_departments, v_dept)
    from public.ai_tree_nodes n
   where n.id in (select id from sub)
     and n.kind = 'conversation'
     and c.id = n.conversation_id
     and c.think_role_id <> v_dept;
  get diagnostics v_changed = row_count;

  return jsonb_build_object('node_id', v_node.id, 'department', v_dept, 'roles_changed', v_changed);
end
$$;

-- 대화를 다른 부서의 미분류로 옮긴다(역할 변경 + 트리에서 빼기).
create or replace function public.ai_conversation_move_department(p_conversation_id uuid, p_department text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return public.ai_conversation_change_department(p_conversation_id, p_department, true);
end
$$;

-- ---------------------------------------------------------------------------
-- 5) 부서 넘기기 제안
-- ---------------------------------------------------------------------------
alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation', 'save_memory', 'memory_card_change', 'handover_department'
  ));

-- 같은 대화의 대기 중인 넘기기 제안은 새 제안으로 대체된다. 지금 부서로는 넘길 수 없다.
create or replace function public.ai_department_handover_propose(p_conversation_id uuid, p_to text, p_reason text)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conv public.ai_conversations;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_to is null or p_to not in ('lead', 'education', 'product', 'engineering') then
    raise exception 'handover_department_invalid' using errcode = '22023';
  end if;
  select * into v_conv from public.ai_conversations where id = p_conversation_id;
  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if v_conv.think_role_id = p_to then
    raise exception 'handover_same_department' using errcode = '22023';
  end if;
  if v_reason = '' then
    raise exception 'handover_reason_required' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = 'handover_department'
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id,
    'handover_department',
    jsonb_build_object('to_department', p_to, 'reason', v_reason),
    jsonb_build_object(
      'title', v_conv.title,
      'from_department', v_conv.think_role_id,
      'to_department', p_to,
      'reason', v_reason
    )
  )
  returning * into v_row;
  return v_row;
end
$$;

-- 20261011100000의 정의에 부서 넘기기 분기만 더했다.
-- p_overrides: 사용자가 카드에서 고친 값만. code_*: {title, spec}, place_conversation: {folder_id},
-- split_conversation: {title, summary, folder_id}, save_memory·memory_card_change: {memory}
create or replace function public.ai_action_apply(p_id uuid, p_overrides jsonb default '{}'::jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
  v_result jsonb;
  v_target uuid;
  v_req_id uuid;
  v_title text;
  v_spec jsonb;
  v_folder uuid;
  v_new_folder uuid;
  v_parent uuid;
  v_node public.ai_tree_nodes;
  v_prev jsonb;
  v_prev_index integer;
  v_deleted_self boolean := false;
  v_to text;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- 나누기는 원본 대화를 먼저 잠가야 해서 따로 처리한다.
  if exists (select 1 from public.ai_actions where id = p_id and kind = 'split_conversation') then
    return public.ai_conversation_split_apply(p_id, v_over);
  end if;
  if exists (select 1 from public.ai_actions where id = p_id and kind in ('save_memory', 'memory_card_change')) then
    return public.ai_memory_action_apply(p_id, v_over);
  end if;
  select * into v_row from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;

  if v_row.kind in ('code_request', 'code_change') then
    v_title := btrim(coalesce(nullif(v_over ->> 'title', ''), v_row.payload ->> 'title', ''));
    v_spec := case when jsonb_typeof(v_over -> 'spec') = 'object' then v_over -> 'spec' else v_row.payload -> 'spec' end;
    if v_title = '' then
      raise exception 'code_request_title_required' using errcode = '22023';
    end if;
    if v_spec is null or jsonb_typeof(v_spec) <> 'object' then
      raise exception 'code_request_goal_required' using errcode = '22023';
    end if;
    insert into public.ai_code_requests (conversation_id, source_message_ids, title, request, mode)
    values (
      v_row.conversation_id,
      array_remove(array[v_row.message_id], null),
      left(v_title, 200),
      v_spec,
      case when v_row.kind = 'code_change' then 'change' else 'investigate' end
    )
    returning id into v_req_id;
    perform public.ai_code_request_submit(v_req_id);
    v_result := jsonb_build_object('code_request_id', v_req_id);

  elsif v_row.kind = 'place_conversation' then
    v_folder := nullif(v_over ->> 'folder_id', '')::uuid;
    if v_folder is null and nullif(btrim(coalesce(v_row.payload ->> 'new_folder_title', '')), '') is not null then
      v_parent := nullif(v_row.payload ->> 'new_folder_parent_id', '')::uuid;
      if v_parent is not null and not exists (select 1 from public.ai_tree_nodes where id = v_parent and kind = 'folder') then
        raise exception 'tree_parent_not_folder' using errcode = '22023';
      end if;
      insert into public.ai_tree_nodes (kind, parent_id, title, created_via, sort_order, department)
      values (
        'folder', v_parent, left(btrim(v_row.payload ->> 'new_folder_title'), 120), 'ai', 2147483647,
        (select think_role_id from public.ai_conversations where id = v_row.conversation_id)
      )
      returning id into v_new_folder;
      perform public.ai_tree_renumber(v_parent);
      v_folder := v_new_folder;
    elsif v_folder is null then
      v_folder := nullif(v_row.payload ->> 'folder_id', '')::uuid;
    end if;
    if v_folder is null or not exists (select 1 from public.ai_tree_nodes where id = v_folder and kind = 'folder') then
      raise exception 'tree_folder_not_found' using errcode = 'P0002';
    end if;

    select * into v_node from public.ai_tree_nodes
     where kind = 'conversation' and conversation_id = v_row.conversation_id;
    if found then
      select count(*) into v_prev_index
        from public.ai_tree_nodes
       where parent_id is not distinct from v_node.parent_id
         and id <> v_node.id
         and (sort_order, created_at, id) < (v_node.sort_order, v_node.created_at, v_node.id);
      v_prev := jsonb_build_object('placed', true, 'parent_id', v_node.parent_id, 'index', v_prev_index);
    else
      v_prev := jsonb_build_object('placed', false);
    end if;
    perform public.ai_tree_place_conversation(v_row.conversation_id, v_folder, 2147483647);
    v_result := jsonb_build_object('folder_id', v_folder, 'created_folder_id', v_new_folder, 'previous', v_prev);

  elsif v_row.kind = 'delete_code_request' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    delete from public.ai_code_requests
     where id = v_target
       and status in ('draft', 'ready', 'needs_review', 'failed', 'cancelled', 'applied', 'apply_failed', 'reverted', 'revert_failed');
    if not found then
      raise exception 'code_request_not_deletable' using errcode = '22023';
    end if;
    v_result := jsonb_build_object('deleted_id', v_target);

  elsif v_row.kind = 'delete_folder' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    perform public.ai_tree_delete_folder(v_target);
    v_result := jsonb_build_object('deleted_id', v_target);

  elsif v_row.kind = 'delete_conversation' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    v_deleted_self := v_target = v_row.conversation_id;
    delete from public.ai_conversations where id = v_target;
    if not found then
      raise exception 'conversation_not_found' using errcode = 'P0002';
    end if;
    v_result := jsonb_build_object('deleted_id', v_target, 'deleted_self', v_deleted_self);

  elsif v_row.kind = 'handover_department' then
    v_to := v_row.payload ->> 'to_department';
    if exists (select 1 from public.ai_conversations where id = v_row.conversation_id and think_role_id = v_to) then
      raise exception 'handover_same_department' using errcode = '22023';
    end if;
    v_result := public.ai_conversation_change_department(v_row.conversation_id, v_to, true);

  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;

  if v_deleted_self then
    -- 제안이 속한 대화가 지워져 행도 함께 사라졌다. 결과만 돌려준다.
    v_row.status := 'applied';
    v_row.result := v_result;
    v_row.decided_at := now();
    v_row.decided_by := auth.uid();
    return v_row;
  end if;

  update public.ai_actions
     set status = 'applied', result = v_result, error = null, decided_at = now(), decided_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- 6) 기능 확인 (20261011100000 정의에 department_work 추가)
-- ---------------------------------------------------------------------------
create or replace function public.ai_think_db_features()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'conversation_split',
    case
      when to_regprocedure('public.ai_conversation_split_propose(uuid, uuid, jsonb, jsonb, boolean)') is not null
       and to_regprocedure('public.ai_conversation_split_apply(uuid, jsonb)') is not null
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'split_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'source_message_id' and not attisdropped
       )
      then 1
      else 0
    end,
    'think_roles',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'think_role_id' and not attisdropped
       )
       and to_regprocedure('public.ai_conversation_set_think_role(uuid, text, text[], text)') is not null
       and to_regprocedure('public.ai_search_memories_scoped(text[], integer, text, text[], uuid[])') is not null
       and to_regclass('public.ai_conversation_memory_links') is not null
       and to_regclass('public.ai_conversation_document_links') is not null
       and to_regclass('public.ai_message_context_snapshots') is not null
      then 1
      else 0
    end,
    'memory_proposals',
    case
      when to_regprocedure('public.ai_memory_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_clean(jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_guard(jsonb, uuid)') is not null
      then 1
      else 0
    end,
    'department_work',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_tree_nodes'::regclass and attname = 'department' and not attisdropped
       )
       and to_regprocedure('public.ai_tree_move_department(uuid, uuid, uuid, integer, text)') is not null
       and to_regprocedure('public.ai_conversation_move_department(uuid, text)') is not null
       and to_regprocedure('public.ai_department_handover_propose(uuid, text, text)') is not null
      then 1
      else 0
    end
  );
end
$$;

revoke all on function public.ai_tree_nodes_department_before() from public, anon, authenticated, service_role;
revoke all on function public.ai_tree_nodes_department_after() from public, anon, authenticated, service_role;
revoke all on function public.ai_tree_conversation_section(uuid) from public, anon;
revoke all on function public.ai_conversation_change_department(uuid, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.ai_tree_move_department(uuid, uuid, uuid, integer, text) from public, anon;
revoke all on function public.ai_conversation_move_department(uuid, text) from public, anon;
revoke all on function public.ai_department_handover_propose(uuid, text, text) from public, anon;
grant execute on function public.ai_tree_conversation_section(uuid) to authenticated;
grant execute on function public.ai_tree_move_department(uuid, uuid, uuid, integer, text) to authenticated;
grant execute on function public.ai_conversation_move_department(uuid, text) to authenticated;
grant execute on function public.ai_department_handover_propose(uuid, text, text) to authenticated;
