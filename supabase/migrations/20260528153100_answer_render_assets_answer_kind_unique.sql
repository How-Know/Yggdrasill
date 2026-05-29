-- 20260528153100: allow multiple answer render variants per source
--
-- A PB question can be assigned in a different mode from its original source
-- type (for example, an objective source question assigned as subjective).
-- Store pre-rendered answer assets per answer_kind so each mode can resolve
-- the correct image independently.

drop index if exists public.uidx_answer_render_assets_source_style;

create unique index if not exists uidx_answer_render_assets_source_kind_style
  on public.answer_render_assets(
    academy_id,
    source_kind,
    source_id,
    answer_kind,
    engine,
    style_version
  );

create index if not exists idx_answer_render_assets_source_kind
  on public.answer_render_assets(
    academy_id,
    source_kind,
    source_id,
    answer_kind
  );
