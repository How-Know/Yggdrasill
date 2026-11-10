-- 원본 해설 속 그림(그래프·도형)을 해설 PDF 에서 잘라 저장한다.
-- 해설 전사본의 [그림] 표시 순서대로 solution_figure_assets[figure_index] 가 대응한다.
--   자산: {figure_index, bucket, path, mime_type, approved, source, width_px, height_px, width_em,
--          raw_page, source_kind, crop_region_1k}
-- solution_figures_checked_at 은 그림 찾기를 마친 시각(그림이 없어도 기록)이다.

alter table public.textbook_problem_analyses
  add column if not exists solution_figure_assets jsonb not null default '[]'::jsonb,
  add column if not exists solution_figures_checked_at timestamptz;

create or replace function public.textbook_review_set_solution_figures(
  p_crop_id uuid,
  p_assets jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assets jsonb := coalesce(p_assets, '[]'::jsonb);
  v_updated int := 0;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if jsonb_typeof(v_assets) <> 'array' then
    raise exception 'textbook_review_bad_solution_figures';
  end if;

  update public.textbook_problem_analyses
     set solution_figure_assets = v_assets,
         solution_figures_checked_at = now(),
         updated_at = now()
   where crop_id = p_crop_id;
  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated, 'count', jsonb_array_length(v_assets));
end;
$$;

revoke all on function public.textbook_review_set_solution_figures(uuid, jsonb) from public, anon;
grant execute on function public.textbook_review_set_solution_figures(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
