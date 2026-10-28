-- 20261023180000: 개념 관계 유형 여섯 가지·맥락·근거·결정 기록·이력, 관계 읽기 RPC, Think 관계 고치기 카드
-- (운영자 결정 2026-10-23, 개념 라이브러리 정리 3단계)
--
-- 설계: docs/architecture/concept-library.md "관계 유형"
--
-- 1) 유형(kind). 모두 "concept_id(이 개념) → related_id(기준 개념)"로 읽는다.
--      extends       확장: 이 개념은 기준 개념의 정의·범위를 넓힌 개념 (있던 유형)
--      special_case  특수한 경우: 이 개념은 기준 개념의 특수한 경우 (있던 유형)
--      kind_of       종류·특수화: 이 개념은 기준 개념의 한 종류
--      part_of       구성·부분: 이 개념은 기준 개념을 이루는 요소
--      derived_from  근거·유도: 이 개념은 기준 개념을 근거로 유도·증명된다. 맥락(어떤 유도·증명)이 있어야 한다.
--      depends_on    학습 의존: 이 개념을 맥락의 목표·방법으로 배우거나 쓰려면 기준 개념이 필요하다. 맥락이 있어야 한다.
--    special_case 와 kind_of 는 따로 둔다(운영자 결정). 있던 줄을 다른 유형으로 바꾸지 않는다.
--    과정 순서로 학습 의존을 넣지 않고, A→B·B→C 에서 A→C 를 만들지 않는다.
-- 2) 한 쌍의 규칙. 확장·특수한 경우는 전처럼 한 방향에 둘 중 한 줄이고 둘 사이 반대 방향을 막는다.
--    새 유형은 유형이 다르면 한 쌍에 여러 줄을 둘 수 있고, 같은 쌍·유형·맥락(앞뒤 공백·대소문자 무시)은 한 줄이다.
--    종류·특수화·구성·부분은 같은 유형의 반대 방향을 막는다(서로가 서로의 한 종류면 같은 개념인지 검토할 일이다).
--    학습 의존·근거·유도는 맥락이 다르면 반대 방향을 둘 수 있다. 세 개 이상 이어진 고리는 검사하지 않는다.
-- 3) 줄마다 맥락(context)·근거(basis)·결정(decided_by·decided_at·decided_via·action_id)·판단 때 두 개념의 글 지문(judged_marks)·판(rev).
--    이 마이그레이션 전에 있던 줄은 결정·지문이 비어 "기록 없음"으로 읽힌다(만들어 넣지 않는다).
--    지금 두 개념의 글 지문(concept_review_text_mark)이 judged_marks 와 다르면 다시 검토할 관계다.
-- 4) concept_relation_events: 넣기·바꾸기·빼기 이력. 개념 이름을 함께 적고 개념을 외래키로 잇지 않아 개념 지우기를 막지 않는다.
-- 5) 읽기 concept_relation_list · 직접 저장 concept_relation_save(판 확인) · 빼기 concept_relation_remove(판 확인).
--    초안 확정·같은 개념 판단은 전과 같은 길(concept_relation_put)로 확장·특수한 경우만 넣는다.
-- 6) Think 카드 concept_relation_change(20개까지, add·change·remove). 사용자가 고른 항목만 빼기 → 바꾸기 → 넣기 순서로 반영한다.
--    제안 뒤 두 개념의 글이나 그 관계(판)가 바뀐 항목은 반영하지 않는다. 빼기는 관계만 빼고 개념은 지우지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 표
-- ─────────────────────────────────────────────────────────────────────────

do $$
declare
  r record;
begin
  for r in
    select c.conname
      from pg_constraint c
     where c.conrelid = 'public.concept_relations'::regclass
       and (c.contype = 'u'
            or (c.contype = 'c' and c.conname <> 'concept_relations_self_chk'
                and (pg_get_constraintdef(c.oid) like '%kind%' or pg_get_constraintdef(c.oid) like '%origin%')))
  loop
    execute format('alter table public.concept_relations drop constraint %I', r.conname);
  end loop;
end
$$;

alter table public.concept_relations
  add column if not exists context text,
  add column if not exists basis text,
  add column if not exists decided_by uuid references auth.users(id) on delete set null,
  add column if not exists decided_at timestamptz,
  add column if not exists decided_via text,
  add column if not exists action_id uuid references public.ai_actions(id) on delete set null,
  add column if not exists judged_marks jsonb,
  add column if not exists rev integer not null default 1,
  add column if not exists updated_at timestamptz;

alter table public.concept_relations
  add constraint concept_relations_kind_chk
    check (kind in ('extends', 'special_case', 'kind_of', 'part_of', 'derived_from', 'depends_on')),
  add constraint concept_relations_origin_chk check (origin in ('draft', 'review', 'manual', 'think')),
  add constraint concept_relations_via_chk check (decided_via is null or decided_via in ('draft', 'review', 'manual', 'think')),
  add constraint concept_relations_context_chk check (context is null or char_length(context) between 1 and 300),
  add constraint concept_relations_basis_chk check (basis is null or char_length(basis) between 1 and 1000),
  add constraint concept_relations_context_required_chk check (kind not in ('derived_from', 'depends_on') or context is not null);

create unique index if not exists concept_relations_legacy_pair_uidx
  on public.concept_relations (concept_id, related_id) where kind in ('extends', 'special_case');
create unique index if not exists concept_relations_typed_uidx
  on public.concept_relations (concept_id, related_id, kind, lower(btrim(coalesce(context, ''))))
  where kind not in ('extends', 'special_case');
create index if not exists concept_relations_concept_idx on public.concept_relations (concept_id);

create table if not exists public.concept_relation_events (
  id uuid primary key default gen_random_uuid(),
  relation_id uuid not null,
  event text not null check (event in ('add', 'change', 'remove')),
  -- 지운 개념도 가리킬 수 있어 외래키가 아니다(이력이 개념 지우기를 막지 않는다). 그때 이름을 함께 적는다.
  concept_id uuid not null,
  related_id uuid not null,
  concept_name text,
  related_name text,
  before jsonb,
  after jsonb,
  via text not null check (via in ('draft', 'review', 'manual', 'think')),
  action_id uuid references public.ai_actions(id) on delete set null,
  action_item integer,
  reason text check (reason is null or char_length(reason) <= 500),
  uncertainty text check (uncertainty is null or char_length(uncertainty) <= 500),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists concept_relation_events_concept_idx on public.concept_relation_events (concept_id, created_at desc);
create index if not exists concept_relation_events_related_idx on public.concept_relation_events (related_id, created_at desc);
create index if not exists concept_relation_events_relation_idx on public.concept_relation_events (relation_id);

alter table public.concept_relation_events enable row level security;

drop policy if exists concept_relation_events_operator_select on public.concept_relation_events;
create policy concept_relation_events_operator_select on public.concept_relation_events
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_relation_events from anon;
revoke insert, update, delete, truncate on public.concept_relation_events from authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 쓰기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_relation_state(r public.concept_relations)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'concept_id', r.concept_id, 'related_id', r.related_id, 'kind', r.kind,
    'context', r.context, 'basis', r.basis, 'note', r.note, 'rev', r.rev
  );
$$;

create or replace function public.concept_relation_text(p text, p_max integer, p_required boolean)
returns text
language plpgsql
immutable
as $$
declare
  v text := nullif(btrim(coalesce(p, '')), '');
begin
  if v is null then
    if p_required then
      raise exception 'concept_relation_text_required';
    end if;
    return null;
  end if;
  if char_length(v) > p_max then
    raise exception 'concept_relation_too_long';
  end if;
  return v;
end;
$$;

-- 관계를 넣거나(p_id null) 바꾼다. 권한은 부르는 쪽이 본다. 돌려주는 값: {id, event: add·change·same}.
--   확장·특수한 경우를 p_id 없이 넣을 때 같은 방향 줄이 있으면: p_strict 면 concept_relation_exists,
--   아니면 전처럼 그 줄의 종류·메모를 바꾼다(초안 확정·같은 개념 판단·옛 앱). 이때 맥락·근거를 주지 않으면 있던 값을 둔다.
--   p_rev 가 있으면 바꾸는 줄의 판이 같아야 한다(concept_relation_stale).
create or replace function public.concept_relation_write(
  p_id uuid,
  p_rev integer,
  p_concept uuid,
  p_related uuid,
  p_kind text,
  p_context text,
  p_basis text,
  p_note text,
  p_via text,
  p_draft uuid,
  p_action uuid,
  p_item integer,
  p_reason text,
  p_uncertainty text,
  p_strict boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_context text := nullif(btrim(coalesce(p_context, '')), '');
  v_basis text := nullif(btrim(coalesce(p_basis, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_legacy boolean := p_kind in ('extends', 'special_case');
  v_old public.concept_relations;
  v_row public.concept_relations;
  v_marks jsonb;
  v_event text;
begin
  if p_kind is null or p_kind not in ('extends', 'special_case', 'kind_of', 'part_of', 'derived_from', 'depends_on') then
    raise exception 'concept_relation_bad_kind';
  end if;
  if p_concept is null or p_related is null or p_concept = p_related then
    raise exception 'concept_relation_bad_request';
  end if;
  if not exists (select 1 from public.concepts where id = p_concept)
     or not exists (select 1 from public.concepts where id = p_related) then
    raise exception 'concept_relation_not_found';
  end if;
  -- 같은 두 개념 사이 쓰기를 한 줄로 세운다(반대 방향 검사가 동시에 통과하지 않게).
  perform pg_advisory_xact_lock(hashtext(
    'concept_relation:' || least(p_concept, p_related)::text || ':' || greatest(p_concept, p_related)::text
  ));

  if p_id is not null then
    select * into v_old from public.concept_relations where id = p_id for update;
    if not found then
      raise exception 'concept_relation_not_found';
    end if;
    if p_rev is not null and v_old.rev <> p_rev then
      raise exception 'concept_relation_stale';
    end if;
  elsif v_legacy then
    select * into v_old
      from public.concept_relations
     where concept_id = p_concept and related_id = p_related and kind in ('extends', 'special_case')
     for update;
    if found then
      if p_strict then
        raise exception 'concept_relation_exists';
      end if;
      v_context := coalesce(v_context, v_old.context);
      v_basis := coalesce(v_basis, v_old.basis);
    end if;
  end if;

  if char_length(coalesce(v_note, '')) > 500 or char_length(coalesce(v_context, '')) > 300
     or char_length(coalesce(v_basis, '')) > 1000 then
    raise exception 'concept_relation_too_long';
  end if;
  if p_kind in ('derived_from', 'depends_on') and v_context is null then
    raise exception 'concept_relation_context_required';
  end if;

  if v_legacy then
    if exists (
      select 1 from public.concept_relations r
       where r.concept_id = p_concept and r.related_id = p_related and r.kind in ('extends', 'special_case')
         and r.id is distinct from v_old.id
    ) then
      raise exception 'concept_relation_exists';
    end if;
    if exists (
      select 1 from public.concept_relations r
       where r.concept_id = p_related and r.related_id = p_concept and r.kind in ('extends', 'special_case')
         and r.id is distinct from v_old.id
    ) then
      raise exception 'concept_relation_reverse_exists';
    end if;
  else
    if exists (
      select 1 from public.concept_relations r
       where r.concept_id = p_concept and r.related_id = p_related and r.kind = p_kind
         and lower(btrim(coalesce(r.context, ''))) = lower(coalesce(v_context, ''))
         and r.id is distinct from v_old.id
    ) then
      raise exception 'concept_relation_exists';
    end if;
    if exists (
      select 1 from public.concept_relations r
       where r.concept_id = p_related and r.related_id = p_concept and r.kind = p_kind
         and (p_kind in ('kind_of', 'part_of') or lower(btrim(coalesce(r.context, ''))) = lower(coalesce(v_context, '')))
         and r.id is distinct from v_old.id
    ) then
      raise exception 'concept_relation_reverse_exists';
    end if;
  end if;

  v_marks := jsonb_build_object(
    'concept', public.concept_review_text_mark(p_concept),
    'related', public.concept_review_text_mark(p_related)
  );

  if v_old.id is null then
    insert into public.concept_relations (
      concept_id, related_id, kind, origin, draft_id, note, context, basis, created_by,
      decided_by, decided_at, decided_via, action_id, judged_marks
    )
    values (
      p_concept, p_related, p_kind, p_via, p_draft, v_note, v_context, v_basis, auth.uid(),
      auth.uid(), now(), p_via, p_action, v_marks
    )
    returning * into v_row;
    v_event := 'add';
  elsif v_old.concept_id = p_concept and v_old.related_id = p_related and v_old.kind = p_kind
        and v_old.context is not distinct from v_context and v_old.basis is not distinct from v_basis
        and v_old.note is not distinct from v_note then
    if p_id is not null then
      raise exception 'concept_relation_unchanged';
    end if;
    -- 같은 관계를 다시 고른 것(초안 확정·같은 개념 판단). 내용은 그대로라 판을 올리지 않는다.
    update public.concept_relations
       set origin = p_via, draft_id = p_draft, decided_by = auth.uid(), decided_at = now(), decided_via = p_via,
           action_id = p_action, judged_marks = v_marks
     where id = v_old.id;
    return jsonb_build_object('id', v_old.id, 'event', 'same');
  else
    update public.concept_relations
       set concept_id = p_concept, related_id = p_related, kind = p_kind, context = v_context, basis = v_basis, note = v_note,
           origin = case when p_id is null then p_via else origin end,
           draft_id = case when p_id is null then p_draft else draft_id end,
           decided_by = auth.uid(), decided_at = now(), decided_via = p_via, action_id = p_action, judged_marks = v_marks,
           rev = rev + 1, updated_at = now()
     where id = v_old.id
    returning * into v_row;
    v_event := 'change';
  end if;

  insert into public.concept_relation_events (
    relation_id, event, concept_id, related_id, concept_name, related_name, before, after,
    via, action_id, action_item, reason, uncertainty, created_by
  )
  values (
    v_row.id, v_event, v_row.concept_id, v_row.related_id,
    (select name from public.concepts where id = v_row.concept_id),
    (select name from public.concepts where id = v_row.related_id),
    case when v_old.id is null then null else public.concept_relation_state(v_old) end,
    public.concept_relation_state(v_row),
    p_via, p_action, p_item, left(p_reason, 500), left(p_uncertainty, 500), auth.uid()
  );
  return jsonb_build_object('id', v_row.id, 'event', v_event);
exception when unique_violation then
  raise exception 'concept_relation_exists';
end;
$$;

-- 관계 한 줄을 뺀다. 두 개념과 다른 관계는 그대로 둔다.
create or replace function public.concept_relation_drop(
  p_id uuid,
  p_rev integer,
  p_via text,
  p_action uuid,
  p_item integer,
  p_reason text,
  p_uncertainty text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.concept_relations;
begin
  select * into v_old from public.concept_relations where id = p_id for update;
  if not found then
    raise exception 'concept_relation_not_found';
  end if;
  if p_rev is not null and v_old.rev <> p_rev then
    raise exception 'concept_relation_stale';
  end if;
  delete from public.concept_relations where id = p_id;
  insert into public.concept_relation_events (
    relation_id, event, concept_id, related_id, concept_name, related_name, before, after,
    via, action_id, action_item, reason, uncertainty, created_by
  )
  values (
    v_old.id, 'remove', v_old.concept_id, v_old.related_id,
    (select name from public.concepts where id = v_old.concept_id),
    (select name from public.concepts where id = v_old.related_id),
    public.concept_relation_state(v_old), null,
    p_via, p_action, p_item, left(p_reason, 500), left(p_uncertainty, 500), auth.uid()
  );
  return jsonb_build_object('id', p_id, 'removed', true);
end;
$$;

-- 초안 확정·같은 개념 판단이 쓰는 길(20261020120000 과 같은 인자). 확장·특수한 경우만 받는다.
create or replace function public.concept_relation_put(
  p_concept uuid,
  p_related uuid,
  p_kind text,
  p_origin text,
  p_draft uuid,
  p_note text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind is null or p_kind not in ('extends', 'special_case') then
    raise exception 'concept_relation_bad_kind';
  end if;
  return (public.concept_relation_write(
    null, null, p_concept, p_related, p_kind, null, null, p_note, p_origin, p_draft, null, null, null, null, false
  ) ->> 'id')::uuid;
end;
$$;

-- 옛 앱의 관계 넣기(맥락·근거 없음). 확장·특수한 경우는 같은 방향 줄의 종류를 바꾼다.
create or replace function public.concept_relation_set(p_concept uuid, p_related uuid, p_kind text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  perform public.concept_relation_assert_operator();
  v := public.concept_relation_write(
    null, null, p_concept, p_related, p_kind, null, null, p_note, 'manual', null, null, null, null, null, false
  );
  return (select to_jsonb(r) from public.concept_relations r where r.id = (v ->> 'id')::uuid);
end;
$$;

-- 개념 상세에서 관계를 넣거나(p_id null) 고친다. 고칠 때는 읽은 판(p_rev)이 지금과 같아야 한다.
create or replace function public.concept_relation_save(
  p_id uuid,
  p_rev integer,
  p_concept uuid,
  p_related uuid,
  p_kind text,
  p_context text default null,
  p_basis text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  perform public.concept_relation_assert_operator();
  if p_id is not null and p_rev is null then
    raise exception 'concept_relation_rev_required';
  end if;
  v := public.concept_relation_write(
    p_id, p_rev, p_concept, p_related, p_kind, p_context, p_basis, p_note, 'manual', null, null, null, null, null, true
  );
  return (select public.concept_relation_json(r, p_concept) from public.concept_relations r where r.id = (v ->> 'id')::uuid);
end;
$$;

drop function if exists public.concept_relation_remove(uuid);
create or replace function public.concept_relation_remove(p_id uuid, p_rev integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.concept_relation_assert_operator();
  return public.concept_relation_drop(p_id, p_rev, 'manual', null, null, null, null);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 읽기
-- ─────────────────────────────────────────────────────────────────────────

-- 관계 한 줄. direction 은 p_focus 개념 쪽에서 본 방향(out: p_focus 가 출발, in: p_focus 가 기준).
-- decision.recorded false 는 결정 기록이 없다는 뜻이다(이 마이그레이션 전 줄). 승인됐다고 읽지 않는다.
-- rereview 는 판단 때 두 개념의 글 지문과 지금이 다른지. 판단 때 지문이 없으면 null(모름).
create or replace function public.concept_relation_json(r public.concept_relations, p_focus uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with m as (
    select a.id as a_id, a.name as a_name, b.id as b_id, b.name as b_name,
           public.concept_review_text_mark(a.id) as ma, public.concept_review_text_mark(b.id) as mb
      from public.concepts a, public.concepts b
     where a.id = r.concept_id and b.id = r.related_id
  )
  select jsonb_build_object(
    'id', r.id,
    'direction', case when r.concept_id = p_focus then 'out' else 'in' end,
    'from', jsonb_build_object('id', m.a_id, 'name', m.a_name, 'text_rev', left(m.ma, 12)),
    'to', jsonb_build_object('id', m.b_id, 'name', m.b_name, 'text_rev', left(m.mb, 12)),
    'kind', r.kind, 'context', r.context, 'basis', r.basis, 'note', r.note,
    'origin', r.origin, 'draft_id', r.draft_id, 'rev', r.rev, 'created_at', r.created_at, 'updated_at', r.updated_at,
    'decision', case when r.decided_at is null then jsonb_build_object('recorded', false)
                     else jsonb_build_object('recorded', true, 'via', r.decided_via, 'at', r.decided_at, 'action_id', r.action_id) end,
    'judged', case when r.judged_marks is null then jsonb_build_object('recorded', false)
                   else jsonb_build_object(
                     'recorded', true,
                     'from_changed', m.ma is distinct from (r.judged_marks ->> 'concept'),
                     'to_changed', m.mb is distinct from (r.judged_marks ->> 'related')
                   ) end,
    'rereview', case when r.judged_marks is null then null
                     else m.ma is distinct from (r.judged_marks ->> 'concept') or m.mb is distinct from (r.judged_marks ->> 'related') end
  )
  from m;
$$;

-- 개념 하나의 나가는·들어오는 관계 전체, 관계 범위 검토 기록 상태, 승인을 기다리는 관계 카드 항목, 최근 이력 20개.
create or replace function public.concept_relation_list(p_concept uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_c public.concepts;
begin
  perform public.concept_relation_assert_operator();
  select * into v_c from public.concepts where id = p_concept;
  if not found then
    raise exception 'concept_relation_not_found';
  end if;
  return jsonb_build_object(
    'id', v_c.id,
    'name', v_c.name,
    'text_rev', left(public.concept_review_text_mark(v_c.id), 12),
    'revision', public.concept_review_revision(public.concept_review_marks(v_c.id)),
    'relations', coalesce((
      select jsonb_agg(public.concept_relation_json(r, p_concept) order by r.created_at, r.id)
        from public.concept_relations r
       where r.concept_id = p_concept or r.related_id = p_concept
    ), '[]'::jsonb),
    'relations_review', public.concept_review_scope_state(p_concept) -> 'relations',
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
               'action_id', a.id, 'item', t.n, 'op', t.e ->> 'op', 'relation_id', t.e ->> 'relation_id',
               'concept_id', t.e ->> 'concept_id', 'related_id', t.e ->> 'related_id', 'kind', t.e ->> 'kind'
             ) order by a.created_at, t.n)
        from public.ai_actions a
        cross join lateral jsonb_array_elements(
          case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
        ) with ordinality as t(e, n)
       where a.kind = 'concept_relation_change' and a.status = 'proposed'
         and (t.e ->> 'concept_id' = p_concept::text or t.e ->> 'related_id' = p_concept::text)
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'event', e.event, 'relation_id', e.relation_id, 'concept_id', e.concept_id, 'related_id', e.related_id,
               'concept_name', e.concept_name, 'related_name', e.related_name, 'before', e.before, 'after', e.after,
               'via', e.via, 'action_id', e.action_id, 'reason', e.reason, 'at', e.created_at
             ) order by e.created_at desc, e.id)
        from (
          select * from public.concept_relation_events
           where concept_id = p_concept or related_id = p_concept
           order by created_at desc, id
           limit 20
        ) e
    ), '[]'::jsonb),
    'event_count', (
      select count(*) from public.concept_relation_events where concept_id = p_concept or related_id = p_concept
    )
  );
end;
$$;

-- 관계 범위 검토(20261023160000)의 관계 지문에 맥락을 더한다. 관계가 없는 개념의 지문은 그대로다.
create or replace function public.concept_review_relation_mark(p_concept_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when exists (select 1 from public.concepts where id = p_concept_id) then md5(coalesce((
    select jsonb_agg(jsonb_build_array(
             r.id, r.concept_id, r.related_id, r.kind, r.note,
             public.concept_review_text_mark(case when r.concept_id = p_concept_id then r.related_id else r.concept_id end)
           ) || case when r.context is null then '[]'::jsonb else jsonb_build_array(r.context) end
           order by r.id)
      from public.concept_relations r
     where r.concept_id = p_concept_id or r.related_id = p_concept_id
  ), '[]'::jsonb)::text) end;
$$;

-- 20261023160000 정의에서 관계 줄에 맥락(context)을 더한다.
create or replace function public.concept_think_detail(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_concept public.concepts;
  v_marks jsonb;
begin
  perform public.course_map_assert_operator();
  select * into v_concept from public.concepts where id = p_concept_id;
  if not found then
    raise exception 'concept_think_concept_not_found';
  end if;
  v_marks := public.concept_review_marks(p_concept_id);
  return public.concept_think_brief(p_concept_id) || jsonb_build_object(
    'content', v_concept.content,
    'content_draft_pending', exists (select 1 from public.concept_content_drafts d where d.concept_id = p_concept_id),
    'statements', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'role', s.role, 'version', s.version, 'has_draft', s.draft is not null,
               'content', s.content
             ) order by (s.role <> 'core'), s.sort_order, s.created_at)
        from public.concept_statements s where s.concept_id = p_concept_id
    ), '[]'::jsonb),
    'attached', public.concept_attachments(p_concept_id),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object(
               'book', f.name, 'grade', s.grade_label,
               'course_key', nullif(public._textbook_course_info(s.grade_label) ->> 'course_key', ''),
               'unit_path', to_jsonb(s.unit_path), 'page', coalesce(s.display_page, s.raw_page),
               'statement_id', s.statement_id
             ) order by s.created_at, s.id)
        from (
          select * from public.concept_sources s0 where s0.concept_id = p_concept_id order by s0.created_at, s0.id limit 300
        ) s
        left join public.resource_files f on f.id = s.book_id
    ), '[]'::jsonb),
    'appearances', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'statement_id', a.statement_id, 'curriculum_code', a.curriculum_code,
               'school_level', a.school_level, 'course_label', a.course_label, 'unit_path', to_jsonb(a.unit_path), 'note', a.note
             ) order by a.created_at, a.id)
        from public.concept_appearances a where a.concept_id = p_concept_id and a.course_unit_id is null
    ), '[]'::jsonb),
    'relations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'direction', case when r.concept_id = p_concept_id then 'out' else 'in' end,
               'kind', r.kind, 'other_id', o.id, 'other_name', o.name, 'origin', r.origin, 'note', r.note,
               'context', r.context, 'created_at', r.created_at
             ) order by r.created_at, r.id)
        from public.concept_relations r
        join public.concepts o on o.id = case when r.concept_id = p_concept_id then r.related_id else r.concept_id end
       where r.concept_id = p_concept_id or r.related_id = p_concept_id
    ), '[]'::jsonb),
    'same_concept_reviews', coalesce((
      select jsonb_agg(t.j order by t.open desc, t.created_at desc)
        from (
          select v.status = 'open' as open, v.created_at, jsonb_build_object(
                   'id', v.id, 'other_id', o.id, 'other_name', o.name, 'reason', v.reason, 'note', v.note,
                   'status', v.status, 'resolution', v.resolution, 'resolution_note', v.resolution_note,
                   'created_at', v.created_at
                 ) as j
            from public.concept_reviews v
            left join public.concepts o on o.id = case when v.concept_id = p_concept_id then v.other_id else v.concept_id end
           where v.concept_id = p_concept_id or v.other_id = p_concept_id
           order by v.status = 'open' desc, v.created_at desc
           limit 20
        ) t
    ), '[]'::jsonb),
    'same_concept_review_count', (
      select count(*) from public.concept_reviews v where v.concept_id = p_concept_id or v.other_id = p_concept_id
    ),
    'review', public.concept_review_scope_state(p_concept_id),
    'revision', public.concept_review_revision(v_marks),
    'statement_versions', v_marks -> 'statements'
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) Think 카드 concept_relation_change
-- ─────────────────────────────────────────────────────────────────────────

alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation', 'save_memory', 'memory_card_change', 'handover_department',
    'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change',
    'concept_draft_change', 'concept_criterion_change', 'concept_draft_rerun',
    'course_map_change', 'course_map_create', 'concept_placement_change', 'concept_library_change',
    'concept_review_record', 'concept_relation_change'
  ));

-- p_payload {items: [{op: add·change·remove, relation_id·rev(change·remove), concept_id·related_id(add),
--                     kind·context·basis·note(add, change는 바꿀 것만. 빈 글은 비움), concept_revision·related_revision,
--                     uncertainty, reason}], reason}
-- revision 은 Think가 읽은 두 개념의 판(앞 12자, 글 지문)이다. 지금과 다르면 제안을 막는다.
-- change·remove 는 출발·기준 개념이 그 관계의 두 개념이다. 방향을 바꾸려면 빼고 새로 넣는다.
create or replace function public.course_think_propose_relation(p_conversation_id uuid, p_payload jsonb, p_reason text)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb := p_payload -> 'items';
  v_item jsonb;
  v_i integer := 0;
  v_op text;
  v_rel public.concept_relations;
  v_moving uuid[];
  v_seen text[] := '{}'::text[];
  v_key text;
  v_from uuid;
  v_to uuid;
  v_a public.concepts;
  v_b public.concepts;
  v_kind text;
  v_context text;
  v_basis text;
  v_note text;
  v_reason text;
  v_uncertainty text;
  v_ma text;
  v_mb text;
  v_after jsonb;
  v_clean jsonb := '[]'::jsonb;
  v_preview jsonb := '[]'::jsonb;
  v_counts jsonb := '{"add": 0, "change": 0, "remove": 0}'::jsonb;
  v_out public.ai_actions;
begin
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'concept_relation_no_items';
  end if;
  if jsonb_array_length(v_items) > 20 then
    raise exception 'concept_relation_too_many';
  end if;
  -- 이 카드에서 빼거나 바꾸는 줄은 넣기의 겹침·반대 방향 검사에서 뺀다(승인 때 빼기·바꾸기를 먼저 한다).
  select coalesce(array_agg(x.id), '{}'::uuid[]) into v_moving
    from (
      select public.course_think_uuid(e ->> 'relation_id') as id
        from jsonb_array_elements(v_items) e
       where jsonb_typeof(e) = 'object' and e ->> 'op' in ('change', 'remove')
    ) x
   where x.id is not null;

  for v_item in select e from jsonb_array_elements(v_items) e loop
    v_i := v_i + 1;
    begin
      if jsonb_typeof(v_item) <> 'object' then
        raise exception 'concept_relation_bad_op';
      end if;
      v_op := v_item ->> 'op';
      if v_op is null or v_op not in ('add', 'change', 'remove') then
        raise exception 'concept_relation_bad_op';
      end if;
      v_reason := public.concept_relation_text(v_item ->> 'reason', 500, true);
      v_uncertainty := public.concept_relation_text(v_item ->> 'uncertainty', 500, false);
      v_rel := null;
      v_after := null;

      if v_op = 'add' then
        v_from := public.course_think_uuid(v_item ->> 'concept_id');
        v_to := public.course_think_uuid(v_item ->> 'related_id');
        v_kind := v_item ->> 'kind';
        v_context := public.concept_relation_text(v_item ->> 'context', 300, false);
        v_basis := public.concept_relation_text(v_item ->> 'basis', 1000, false);
        v_note := public.concept_relation_text(v_item ->> 'note', 500, false);
      else
        select * into v_rel from public.concept_relations where id = public.course_think_uuid(v_item ->> 'relation_id');
        if not found then
          raise exception 'concept_relation_not_found';
        end if;
        if coalesce(v_item ->> 'rev', '') !~ '^[0-9]+$' then
          raise exception 'concept_relation_rev_required';
        end if;
        if (v_item ->> 'rev')::integer <> v_rel.rev then
          raise exception 'concept_relation_stale';
        end if;
        v_from := v_rel.concept_id;
        v_to := v_rel.related_id;
        v_kind := coalesce(nullif(btrim(coalesce(v_item ->> 'kind', '')), ''), v_rel.kind);
        v_context := case when jsonb_typeof(v_item -> 'context') = 'string'
                          then public.concept_relation_text(v_item ->> 'context', 300, false) else v_rel.context end;
        v_basis := case when jsonb_typeof(v_item -> 'basis') = 'string'
                        then public.concept_relation_text(v_item ->> 'basis', 1000, false) else v_rel.basis end;
        v_note := case when jsonb_typeof(v_item -> 'note') = 'string'
                       then public.concept_relation_text(v_item ->> 'note', 500, false) else v_rel.note end;
        if v_op = 'change' and v_kind = v_rel.kind and v_context is not distinct from v_rel.context
           and v_basis is not distinct from v_rel.basis and v_note is not distinct from v_rel.note then
          raise exception 'concept_relation_unchanged';
        end if;
      end if;

      select * into v_a from public.concepts where id = v_from;
      if not found then
        raise exception 'concept_relation_concept_not_found';
      end if;
      select * into v_b from public.concepts where id = v_to;
      if not found then
        raise exception 'concept_relation_concept_not_found';
      end if;
      if v_from = v_to then
        raise exception 'concept_relation_bad_request';
      end if;

      if v_op <> 'remove' then
        if v_kind is null or v_kind not in ('extends', 'special_case', 'kind_of', 'part_of', 'derived_from', 'depends_on') then
          raise exception 'concept_relation_bad_kind';
        end if;
        if v_kind in ('derived_from', 'depends_on') and v_context is null then
          raise exception 'concept_relation_context_required';
        end if;
        if v_kind in ('extends', 'special_case') then
          if exists (
            select 1 from public.concept_relations r
             where r.concept_id = v_from and r.related_id = v_to and r.kind in ('extends', 'special_case')
               and r.id <> all (v_moving)
          ) then
            raise exception 'concept_relation_exists';
          end if;
          if exists (
            select 1 from public.concept_relations r
             where r.concept_id = v_to and r.related_id = v_from and r.kind in ('extends', 'special_case')
               and r.id <> all (v_moving)
          ) then
            raise exception 'concept_relation_reverse_exists';
          end if;
        else
          if exists (
            select 1 from public.concept_relations r
             where r.concept_id = v_from and r.related_id = v_to and r.kind = v_kind
               and lower(btrim(coalesce(r.context, ''))) = lower(coalesce(v_context, ''))
               and r.id <> all (v_moving)
          ) then
            raise exception 'concept_relation_exists';
          end if;
          if exists (
            select 1 from public.concept_relations r
             where r.concept_id = v_to and r.related_id = v_from and r.kind = v_kind
               and (v_kind in ('kind_of', 'part_of') or lower(btrim(coalesce(r.context, ''))) = lower(coalesce(v_context, '')))
               and r.id <> all (v_moving)
          ) then
            raise exception 'concept_relation_reverse_exists';
          end if;
        end if;
        v_after := jsonb_build_object('kind', v_kind, 'context', v_context, 'basis', v_basis, 'note', v_note);
      end if;

      -- Think가 읽은 두 개념의 글이 지금과 같아야 한다.
      v_ma := public.concept_review_text_mark(v_from);
      v_mb := public.concept_review_text_mark(v_to);
      if nullif(btrim(coalesce(v_item ->> 'concept_revision', '')), '') is null
         or nullif(btrim(coalesce(v_item ->> 'related_revision', '')), '') is null then
        raise exception 'concept_relation_revision_required';
      end if;
      if split_part(btrim(v_item ->> 'concept_revision'), '-', 1) <> left(v_ma, 12)
         or split_part(btrim(v_item ->> 'related_revision'), '-', 1) <> left(v_mb, 12) then
        raise exception 'concept_relation_concept_stale';
      end if;

      v_key := case when v_op = 'remove' then null
                    when v_kind in ('extends', 'special_case') then v_from::text || '>' || v_to::text || ':legacy'
                    else v_from::text || '>' || v_to::text || ':' || v_kind || ':' || lower(coalesce(v_context, '')) end;
      if (v_rel.id is not null and ('rel:' || v_rel.id::text) = any (v_seen)) or (v_key is not null and v_key = any (v_seen)) then
        raise exception 'concept_relation_duplicate';
      end if;
      v_seen := v_seen || array_remove(array[case when v_rel.id is not null then 'rel:' || v_rel.id::text end, v_key], null);

      v_clean := v_clean || jsonb_build_array(jsonb_build_object(
        'op', v_op, 'relation_id', v_rel.id, 'rev', v_rel.rev, 'concept_id', v_from, 'related_id', v_to,
        'kind', v_after ->> 'kind', 'context', v_after ->> 'context', 'basis', v_after ->> 'basis', 'note', v_after ->> 'note',
        'uncertainty', v_uncertainty, 'reason', v_reason,
        'marks', jsonb_build_object('concept', v_ma, 'related', v_mb)
      ));
      v_preview := v_preview || jsonb_build_array(jsonb_build_object(
        'i', v_i, 'op', v_op, 'relation_id', v_rel.id,
        'from', jsonb_build_object('id', v_a.id, 'name', v_a.name, 'folder', to_jsonb(public.concept_folder_path(v_a.main_category_id))),
        'to', jsonb_build_object('id', v_b.id, 'name', v_b.name, 'folder', to_jsonb(public.concept_folder_path(v_b.main_category_id))),
        'before', case when v_rel.id is null then null else public.concept_relation_state(v_rel) || jsonb_build_object(
          'origin', v_rel.origin, 'decided', v_rel.decided_at is not null
        ) end,
        'after', v_after,
        'uncertainty', v_uncertainty,
        'reason', v_reason,
        'open_same_concept_review', exists (
          select 1 from public.concept_reviews v
           where v.status = 'open'
             and ((v.concept_id = v_from and v.other_id = v_to) or (v.concept_id = v_to and v.other_id = v_from))
        ),
        'pending_elsewhere', (
          select count(*)
            from public.ai_actions a
            cross join lateral jsonb_array_elements(
              case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
            ) x
           where a.kind = 'concept_relation_change' and a.status = 'proposed'
             and ((v_rel.id is not null and x ->> 'relation_id' = v_rel.id::text)
                  or (x ->> 'concept_id' in (v_from::text, v_to::text) and x ->> 'related_id' in (v_from::text, v_to::text)))
        )
      ));
      v_counts := jsonb_set(v_counts, array[v_op], to_jsonb((v_counts ->> v_op)::integer + 1));
    exception when others then
      raise exception 'concept_relation_bad_item:%:%', v_i, sqlerrm;
    end;
  end loop;

  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id, 'concept_relation_change',
    jsonb_build_object('items', v_clean, 'reason', p_reason),
    jsonb_build_object('title', '개념 관계 고치기', 'items', v_preview, 'counts', v_counts, 'reason', p_reason)
  )
  returning * into v_out;
  return v_out;
end;
$$;

-- p_overrides {skip: [항목 번호]}. 고른 항목만 빼기 → 바꾸기 → 넣기 순서로 따로 반영한다.
-- 제안 뒤 두 개념의 글이나 관계의 판이 바뀐 항목, 이미 같은 관계가 있는 넣기는 반영하지 않는다.
create or replace function public.course_think_apply_relation(p_act public.ai_actions, p_overrides jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_skip integer[];
  v_items jsonb := p_act.payload -> 'items';
  v_i integer;
  v_item jsonb;
  v_op text;
  v_out jsonb;
  v_res jsonb := '[]'::jsonb;
  v_applied integer := 0;
  v_failed integer := 0;
  v_skipped integer := 0;
  v_first text;
begin
  begin
    v_skip := array(select x::integer from jsonb_array_elements_text(coalesce(p_overrides -> 'skip', '[]'::jsonb)) x);
  exception when others then
    raise exception 'course_think_bad_overrides';
  end;

  for v_i in
    select t.n::integer
      from jsonb_array_elements(v_items) with ordinality as t(e, n)
     order by case t.e ->> 'op' when 'remove' then 1 when 'change' then 2 else 3 end, t.n
  loop
    v_item := v_items -> (v_i - 1);
    v_op := v_item ->> 'op';
    if v_i = any (v_skip) then
      v_skipped := v_skipped + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'skipped'));
      continue;
    end if;
    begin
      perform 1 from public.concepts where id = (v_item ->> 'concept_id')::uuid for share;
      if not found then
        raise exception 'concept_relation_concept_not_found';
      end if;
      perform 1 from public.concepts where id = (v_item ->> 'related_id')::uuid for share;
      if not found then
        raise exception 'concept_relation_concept_not_found';
      end if;
      if public.concept_review_text_mark((v_item ->> 'concept_id')::uuid) is distinct from v_item -> 'marks' ->> 'concept'
         or public.concept_review_text_mark((v_item ->> 'related_id')::uuid) is distinct from v_item -> 'marks' ->> 'related' then
        raise exception 'concept_relation_concept_stale';
      end if;
      if v_op = 'remove' then
        v_out := public.concept_relation_drop(
          (v_item ->> 'relation_id')::uuid, (v_item ->> 'rev')::integer, 'think', p_act.id, v_i,
          v_item ->> 'reason', v_item ->> 'uncertainty'
        );
      else
        v_out := public.concept_relation_write(
          case when v_op = 'change' then (v_item ->> 'relation_id')::uuid end,
          case when v_op = 'change' then (v_item ->> 'rev')::integer end,
          (v_item ->> 'concept_id')::uuid, (v_item ->> 'related_id')::uuid, v_item ->> 'kind',
          v_item ->> 'context', v_item ->> 'basis', v_item ->> 'note',
          'think', null, p_act.id, v_i, v_item ->> 'reason', v_item ->> 'uncertainty', true
        );
      end if;
      v_applied := v_applied + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object(
        'i', v_i, 'status', 'applied', 'op', v_op, 'relation_id', v_out ->> 'id',
        'concept_id', v_item ->> 'concept_id', 'related_id', v_item ->> 'related_id'
      ));
    exception when others then
      v_failed := v_failed + 1;
      v_first := coalesce(v_first, sqlerrm);
      v_res := v_res || jsonb_build_array(jsonb_build_object(
        'i', v_i, 'status', 'failed', 'code', left(sqlerrm, 200),
        'concept_id', v_item ->> 'concept_id', 'related_id', v_item ->> 'related_id'
      ));
    end;
  end loop;

  if v_applied = 0 then
    if v_failed = 0 then
      raise exception 'course_think_nothing_selected';
    end if;
    raise exception 'course_think_all_failed:%', v_first;
  end if;
  return jsonb_build_object(
    'items', (select jsonb_agg(e order by (e ->> 'i')::integer) from jsonb_array_elements(v_res) e),
    'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped
  );
end;
$$;

-- 20261023160000 정의에 concept_relation_change 추가.
create or replace function public.course_think_action_propose(p_conversation_id uuid, p_kind text, p_payload jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_reason text := left(btrim(coalesce(p_payload ->> 'reason', '')), 500);
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if octet_length(v_payload::text) > 200000 then
    raise exception 'course_think_too_long';
  end if;
  if v_reason = '' then
    raise exception 'course_think_reason_required';
  end if;
  if p_kind = 'course_map_change' then
    return public.course_think_propose_map(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'course_map_create' then
    return public.course_think_propose_create(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_placement_change' then
    return public.course_think_propose_placement(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_library_change' then
    return public.course_think_propose_library(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_review_record' then
    return public.course_think_propose_review(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_relation_change' then
    return public.course_think_propose_relation(p_conversation_id, v_payload, v_reason);
  end if;
  raise exception 'action_kind_not_appliable' using errcode = '22023';
end;
$$;

create or replace function public.course_think_action_apply(p_id uuid, p_overrides jsonb default '{}'::jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.ai_actions;
  v_res jsonb;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_act from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_act.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  if jsonb_typeof(v_over) <> 'object' then
    raise exception 'course_think_bad_overrides';
  end if;
  if v_act.kind = 'course_map_change' then
    v_res := public.course_think_apply_map(v_act);
  elsif v_act.kind = 'course_map_create' then
    v_res := public.course_think_apply_create(v_act);
  elsif v_act.kind = 'concept_placement_change' then
    v_res := public.course_think_apply_placement(v_act, v_over);
  elsif v_act.kind = 'concept_library_change' then
    v_res := public.course_think_apply_library(v_act, v_over);
  elsif v_act.kind = 'concept_review_record' then
    v_res := public.course_think_apply_review(v_act, v_over);
  elsif v_act.kind = 'concept_relation_change' then
    v_res := public.course_think_apply_relation(v_act, v_over);
  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'applied', result = v_res, error = null, decided_by = auth.uid(), decided_at = now()
   where id = p_id
  returning * into v_act;
  return v_act;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 기능 확인 (20261023160000 정의에 concept_relation_change 추가)
-- ─────────────────────────────────────────────────────────────────────────
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
    end,
    'auto_organize',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'marked_important' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'progress_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_platform_settings'::regclass and attname = 'auto_organize_enabled' and not attisdropped
       )
       and to_regclass('public.ai_department_criteria') is not null
       and to_regprocedure('public.ai_context_exclusion_propose(uuid, uuid[], text, text, boolean)') is not null
       and to_regprocedure('public.ai_importance_mark_propose(uuid, uuid[], text, boolean)') is not null
       and to_regprocedure('public.ai_progress_summary_propose(uuid, jsonb, text, uuid)') is not null
       and to_regprocedure('public.ai_department_criteria_propose(uuid, text, jsonb, text)') is not null
       and to_regprocedure('public.ai_department_criteria_save(text, jsonb, integer)') is not null
       and to_regprocedure('public.ai_action_apply_batch(jsonb)') is not null
      then 1
      else 0
    end,
    'course_map_actions',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_appearances'::regclass and attname = 'course_unit_id' and not attisdropped
       )
       and to_regprocedure('public.course_think_action_propose(uuid, text, jsonb)') is not null
       and to_regprocedure('public.course_think_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.course_map_placements(uuid)') is not null
       and to_regprocedure('public.concept_placement_candidates(uuid, text, text, integer, integer)') is not null
       and to_regprocedure('public.concept_think_detail(uuid)') is not null
      then 1
      else 0
    end,
    'concept_review',
    case
      when to_regclass('public.concept_quality_reviews') is not null
       and to_regclass('public.concept_review_walks') is not null
       and to_regprocedure('public.concept_review_walk(uuid, jsonb, integer, integer)') is not null
       and to_regprocedure('public.concept_review_status(uuid[])') is not null
       and to_regprocedure('public.course_think_propose_review(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_review(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_relation_change',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_relations'::regclass and attname = 'judged_marks' and not attisdropped
       )
       and to_regclass('public.concept_relation_events') is not null
       and to_regprocedure('public.concept_relation_list(uuid)') is not null
       and to_regprocedure('public.course_think_propose_relation(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_relation(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end
  );
end
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_relation_state(public.concept_relations) from public, anon, authenticated;
revoke all on function public.concept_relation_text(text, integer, boolean) from public, anon, authenticated;
revoke all on function public.concept_relation_write(
  uuid, integer, uuid, uuid, text, text, text, text, text, uuid, uuid, integer, text, text, boolean
) from public, anon, authenticated;
revoke all on function public.concept_relation_drop(uuid, integer, text, uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.concept_relation_put(uuid, uuid, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.concept_relation_json(public.concept_relations, uuid) from public, anon, authenticated;
revoke all on function public.concept_review_relation_mark(uuid) from public, anon, authenticated;
revoke all on function public.course_think_propose_relation(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.course_think_apply_relation(public.ai_actions, jsonb) from public, anon, authenticated;

revoke all on function public.concept_relation_set(uuid, uuid, text, text) from public, anon;
revoke all on function public.concept_relation_save(uuid, integer, uuid, uuid, text, text, text, text) from public, anon;
revoke all on function public.concept_relation_remove(uuid, integer) from public, anon;
revoke all on function public.concept_relation_list(uuid) from public, anon;
revoke all on function public.concept_think_detail(uuid) from public, anon;
revoke all on function public.course_think_action_propose(uuid, text, jsonb) from public, anon;
revoke all on function public.course_think_action_apply(uuid, jsonb) from public, anon;

grant execute on function public.concept_relation_set(uuid, uuid, text, text) to authenticated;
grant execute on function public.concept_relation_save(uuid, integer, uuid, uuid, text, text, text, text) to authenticated;
grant execute on function public.concept_relation_remove(uuid, integer) to authenticated;
grant execute on function public.concept_relation_list(uuid) to authenticated;
grant execute on function public.concept_think_detail(uuid) to authenticated;
grant execute on function public.course_think_action_propose(uuid, text, jsonb) to authenticated;
grant execute on function public.course_think_action_apply(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
