-- 코드 정합성 점검(AI 없음, 사양 5-2·구현 범위 6)
--
-- 점검은 Edge(ai_think textbook_problem_consistency)가 한다. 고칠 수 있는 것은 반영 대기 값으로 쌓고,
-- 나머지는 textbook_review_findings 에 check_key 'consistency:<규칙>' 지적으로 남긴다.
--
-- textbook_review_unit_overview: 정합성 지적을 일반 지적(findings)에서 떼어 consistency_issues 로 낸다.
--   정합성 지적은 준비됨을 막고 사장님이 고치거나 "문제 없음"으로 닫는다.
--   정답 일괄 수정 같은 AI 단계가 정합성 지적을 자기 대상으로 삼지 않도록 일반 지적과 섞지 않는다.

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
             (public.textbook_review_overlay_staged(e.item, an.staged_changes) - 'findings')
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
                    'meta_sources', coalesce(an.meta_sources, '{}'::jsonb)
                  )
             order by e.ord)
      from jsonb_array_elements(coalesce(v -> 'items', '[]'::jsonb)) with ordinality as e(item, ord)
      left join public.textbook_problem_analyses an
        on an.crop_id = (e.item ->> 'crop_id')::uuid
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
