-- 20261020140000: 기본 서술(개념 본문) 수정안과 고친 이유 (운영자 결정 2026-10-20, 여러 교재 설명 통합 1단계)
--
-- 설계: docs/architecture/concept-library.md §4.2
--
-- 기본 서술(concepts.content)은 그 개념의 대표 서술 자리다. 앱·Think·Edge가 모두 이 열을 읽으므로 저장 위치는 그대로 두고,
-- 확정본(concepts.content)과 수정안(concept_content_drafts)을 나눈다. 수정안은 운영자가 확정해야 본문이 된다.
-- 기존 본문의 성격(원문인지, 정리한 글인지)은 이 파일에서 정하거나 새로 붙이지 않는다.
--
-- 표
--   concept_content_drafts     개념마다 수정안 하나. 수정안을 쓸 때 본 본문의 md5(base_md5)를 함께 둔다.
--                              그 뒤 본문이 바뀌면(개념 수정 창 등) 바탕이 바뀐 수정안이라 확정할 수 없다.
--                              지금 본문과 비교해 다시 저장하면 새 바탕으로 바뀐다.
--   concept_content_revisions  열 추가: via('direct' 수정안 없이 바로 고침 / 'draft' 수정안 확정)·note(고친 이유)·draft_origin.
--                              이 파일 전에 쌓인 줄은 개념 수정 창으로 바로 고친 것이라 via = 'direct' 이고 이유는 비어 있다.
--
-- 접근
--   슈퍼관리자만 읽는다. 수정안은 아래 RPC로만 바뀐다. 'ai' 수정안은 운영자가 승인한 제안으로만 들어온다(1단계에는 그 길이 없다).

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 수정안
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_content_drafts (
  concept_id uuid primary key references public.concepts(id) on delete cascade,
  content text not null check (btrim(content) <> '' and char_length(content) <= 40000),
  base_md5 text not null check (base_md5 ~ '^[0-9a-f]{32}$'),
  -- 왜 고치려는지. 확정할 때 이유 칸의 처음 값이 된다.
  note text check (note is null or char_length(note) <= 2000),
  origin text not null default 'owner' check (origin in ('owner', 'ai')),
  saved_at timestamptz not null,
  saved_by uuid references auth.users(id) on delete set null
);

alter table public.concept_content_revisions
  add column if not exists via text not null default 'direct',
  add column if not exists note text,
  add column if not exists draft_origin text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'concept_content_revisions_via_chk') then
    alter table public.concept_content_revisions
      add constraint concept_content_revisions_via_chk check (
        (via = 'direct' and note is null and draft_origin is null)
        or (via = 'draft' and note is not null and draft_origin in ('owner', 'ai'))
      );
  end if;
end $$;

-- 고치기 전 값을 남긴다. 수정안 확정(concept_content_confirm)은 같은 거래 안에서 이유·출처를 넘긴다.
create or replace function public.concept_content_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_via text := nullif(current_setting('ygg.concept_content_via', true), '');
begin
  if v_via = 'draft' then
    insert into public.concept_content_revisions (concept_id, name, content, changed_by, via, note, draft_origin)
    values (old.id, old.name, old.content, auth.uid(), 'draft',
            current_setting('ygg.concept_content_note', true), current_setting('ygg.concept_content_origin', true));
  else
    insert into public.concept_content_revisions (concept_id, name, content, changed_by)
    values (old.id, old.name, old.content, auth.uid());
  end if;
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 수정안 RPC
-- ─────────────────────────────────────────────────────────────────────────

-- 개념 줄을 잠그고 지금 본문을 돌려준다.
create or replace function public.concept_content_lock_concept(p_concept_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_content text;
begin
  select content into v_content from public.concepts where id = p_concept_id for update;
  if not found then
    raise exception 'concept_content_concept_not_found';
  end if;
  return v_content;
end;
$$;

-- 수정안 줄을 잠근다. 화면에 보였던 저장 시각(없었으면 null)과 다르면 stale.
create or replace function public.concept_content_lock_draft(p_concept_id uuid, p_expected_saved_at timestamptz)
returns public.concept_content_drafts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_content_drafts;
begin
  select * into v_row from public.concept_content_drafts where concept_id = p_concept_id for update;
  if v_row.saved_at is distinct from p_expected_saved_at then
    raise exception 'concept_content_draft_stale';
  end if;
  return v_row;
end;
$$;

-- 수정안 저장. p_base_md5 는 화면에 보였던 본문의 md5 다. 그사이 본문이 바뀌었으면 막는다(concept_content_stale).
-- 지금 본문과 같은 글이면 수정안을 지운다({concept_id, removed: true}).
create or replace function public.concept_content_save_draft(
  p_concept_id uuid,
  p_content text,
  p_note text,
  p_base_md5 text,
  p_expected_saved_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_row public.concept_content_drafts;
begin
  perform public.concept_statement_assert_operator();
  v_current := public.concept_content_lock_concept(p_concept_id);
  if p_base_md5 is distinct from md5(v_current) then
    raise exception 'concept_content_stale';
  end if;
  perform public.concept_content_lock_draft(p_concept_id, p_expected_saved_at);
  if p_content is null or btrim(p_content) = '' then
    raise exception 'concept_content_required';
  end if;
  if char_length(p_content) > 40000 or char_length(coalesce(v_note, '')) > 2000 then
    raise exception 'concept_content_too_long';
  end if;
  if p_content = v_current then
    delete from public.concept_content_drafts where concept_id = p_concept_id;
    return jsonb_build_object('concept_id', p_concept_id, 'removed', true);
  end if;
  insert into public.concept_content_drafts (concept_id, content, base_md5, note, origin, saved_at, saved_by)
  values (p_concept_id, p_content, p_base_md5, v_note, 'owner', clock_timestamp(), auth.uid())
  on conflict (concept_id) do update
     set content = excluded.content, base_md5 = excluded.base_md5, note = excluded.note,
         origin = excluded.origin, saved_at = excluded.saved_at, saved_by = excluded.saved_by
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 저장된 수정안을 본문으로 올린다. 이유는 꼭 남긴다. 수정안을 쓴 뒤 본문이 바뀌었으면 막는다(concept_content_base_changed).
-- 다른 서술·출처·등장 위치·관계는 바꾸지 않는다.
create or replace function public.concept_content_confirm(
  p_concept_id uuid,
  p_expected_saved_at timestamptz,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_row public.concept_content_drafts;
begin
  perform public.concept_statement_assert_operator();
  v_current := public.concept_content_lock_concept(p_concept_id);
  if p_expected_saved_at is null then
    raise exception 'concept_content_no_draft';
  end if;
  v_row := public.concept_content_lock_draft(p_concept_id, p_expected_saved_at);
  if v_row.concept_id is null then
    raise exception 'concept_content_no_draft';
  end if;
  if v_row.base_md5 <> md5(v_current) then
    raise exception 'concept_content_base_changed';
  end if;
  if v_note is null then
    raise exception 'concept_content_note_required';
  end if;
  if char_length(v_note) > 2000 then
    raise exception 'concept_content_too_long';
  end if;
  perform set_config('ygg.concept_content_via', 'draft', true);
  perform set_config('ygg.concept_content_note', v_note, true);
  perform set_config('ygg.concept_content_origin', v_row.origin, true);
  update public.concepts set content = v_row.content where id = p_concept_id;
  perform set_config('ygg.concept_content_via', '', true);
  perform set_config('ygg.concept_content_note', '', true);
  perform set_config('ygg.concept_content_origin', '', true);
  delete from public.concept_content_drafts where concept_id = p_concept_id;
  return jsonb_build_object('concept_id', p_concept_id, 'content', v_row.content);
end;
$$;

-- 저장된 수정안을 버린다. 본문은 그대로다.
create or replace function public.concept_content_discard_draft(p_concept_id uuid, p_expected_saved_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_content_drafts;
begin
  perform public.concept_statement_assert_operator();
  if p_expected_saved_at is null then
    raise exception 'concept_content_no_draft';
  end if;
  v_row := public.concept_content_lock_draft(p_concept_id, p_expected_saved_at);
  if v_row.concept_id is null then
    raise exception 'concept_content_no_draft';
  end if;
  delete from public.concept_content_drafts where concept_id = p_concept_id;
  return jsonb_build_object('concept_id', p_concept_id, 'removed', true);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_content_drafts enable row level security;

drop policy if exists concept_content_drafts_operator_select on public.concept_content_drafts;
create policy concept_content_drafts_operator_select on public.concept_content_drafts
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_content_drafts from anon;
revoke insert, update, delete, truncate on public.concept_content_drafts from authenticated;

revoke all on function public.concept_content_history() from public, anon, authenticated;
revoke all on function public.concept_content_lock_concept(uuid) from public, anon, authenticated;
revoke all on function public.concept_content_lock_draft(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.concept_content_save_draft(uuid, text, text, text, timestamptz) from public, anon;
revoke all on function public.concept_content_confirm(uuid, timestamptz, text) from public, anon;
revoke all on function public.concept_content_discard_draft(uuid, timestamptz) from public, anon;

grant execute on function public.concept_content_save_draft(uuid, text, text, text, timestamptz) to authenticated;
grant execute on function public.concept_content_confirm(uuid, timestamptz, text) to authenticated;
grant execute on function public.concept_content_discard_draft(uuid, timestamptz) to authenticated;

notify pgrst, 'reload schema';
