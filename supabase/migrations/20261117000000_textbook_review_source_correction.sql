-- 인쇄된 원본(교재·시험지)의 문항 본문이 틀려 사장님이 고친 문항을 "원본 오류 교정"으로 표시한다(2026-11-17 사장님 결정).
-- 표시한 문항은 검수가 고친 부분을 사장님 본문과 대조하고 나머지(그림·선지 등)는 계속 원본과 대조한다.
-- 교정 전 본문·선지는 여기에 따로 남긴다(해설 교정의 solution_transcribed_original 과 같은 방식).

-- 1) 교정 전 본문·선지: { "stem": 교정 전 본문, "choices": 교정 전 선지, "marked_at": 시각 }. 표시한 문항에만 있다.
alter table public.textbook_problem_analyses
  add column if not exists source_correction jsonb;

comment on column public.textbook_problem_analyses.source_correction is
  '사장님이 원본 오류 교정으로 표시한 문항의 교정 전 본문·선지. 표시한 문항에만 있다.';

-- 2) 표시·해제. 표시할 때 문제은행에 있는 지금 본문·선지(교정이 반영되기 전 값)를 남긴다.
--    이미 표시한 문항은 남겨 둔 교정 전 값을 바꾸지 않는다.
create or replace function public.textbook_review_mark_source_correction(p_crop_id uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stem text;
  v_choices jsonb;
  v_found boolean := false;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if not coalesce(p_on, false) then
    update public.textbook_problem_analyses
       set source_correction = null,
           updated_at = now()
     where crop_id = p_crop_id
       and source_correction is not null;
    return jsonb_build_object('ok', true, 'marked', false);
  end if;

  select q.stem, q.choices, true
    into v_stem, v_choices, v_found
    from public.pb_questions q
   where q.id = public.textbook_review_linked_pb_question(p_crop_id);
  if not coalesce(v_found, false) then
    raise exception 'textbook_review_question_not_linked';
  end if;

  update public.textbook_problem_analyses
     set source_correction = jsonb_build_object(
           'stem', coalesce(v_stem, ''),
           'choices', coalesce(v_choices, '[]'::jsonb),
           'marked_at', now()
         ),
         updated_at = now()
   where crop_id = p_crop_id
     and source_correction is null;
  if not found and not exists (select 1 from public.textbook_problem_analyses where crop_id = p_crop_id) then
    raise exception 'textbook_review_analysis_not_found';
  end if;
  return jsonb_build_object('ok', true, 'marked', true);
end;
$$;

revoke all on function public.textbook_review_mark_source_correction(uuid, boolean) from public, anon;
grant execute on function public.textbook_review_mark_source_correction(uuid, boolean) to authenticated;

-- 3) overview 에 표시를 함께 준다(20261114120000 의 정의에 source_correction 한 항목만 더함).
create or replace function public.textbook_review_unit_overview(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  v := public.textbook_review_unit_overview_base(p_academy_id, p_book_id, p_grade_label, p_big_order, p_mid_order);
  return (v - 'items') || jsonb_build_object('items', coalesce((
    select jsonb_agg(
             (public.textbook_review_overlay_staged(
                e.item || jsonb_build_object('pb_common_figure_layout', pq.meta #> '{set_model,common_figure_layout}'),
                an.staged_changes
              ) - 'findings')
               || jsonb_build_object(
                    'findings', coalesce((
                      select jsonb_agg(fx.f order by fx.ord)
                        from jsonb_array_elements(coalesce(e.item -> 'findings', '[]'::jsonb)) with ordinality as fx(f, ord)
                       where not exists (
                         select 1
                           from jsonb_array_elements(cons.list) ci
                          where ci ->> 'id' = fx.f ->> 'id'
                       )
                    ), '[]'::jsonb),
                    'consistency_issues', cons.list,
                    'concept_proposals', coalesce(an.concept_proposals, '[]'::jsonb),
                    'meta_checked_at', an.meta_checked_at,
                    'meta_sources', coalesce(an.meta_sources, '{}'::jsonb),
                    'source_correction', an.source_correction
                  )
             order by e.ord)
      from jsonb_array_elements(coalesce(v -> 'items', '[]'::jsonb)) with ordinality as e(item, ord)
      left join public.textbook_problem_analyses an
        on an.crop_id = (e.item ->> 'crop_id')::uuid
      left join public.pb_questions pq
        on pq.id = nullif(e.item ->> 'pb_question_id', '')::uuid
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', f.id,
                 'code', substr(f.check_key, length('consistency:') + 1),
                 'axis', f.axis,
                 'title', f.title,
                 'detail', f.detail,
                 'status', f.status
               ) order by f.created_at), '[]'::jsonb) as list
          from public.textbook_review_findings f
         where f.academy_id = p_academy_id
           and f.crop_id = (e.item ->> 'crop_id')::uuid
           and f.check_key <> ''
           and f.check_key like 'consistency:%'
           and f.status in ('open', 'held')
      ) cons
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) from public, anon;
grant execute on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) to authenticated;

notify pgrst, 'reload schema';
