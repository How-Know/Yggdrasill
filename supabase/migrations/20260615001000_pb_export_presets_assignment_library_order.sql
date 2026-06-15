alter table public.pb_export_presets
  add column if not exists assignment_library_order integer;

update public.pb_export_presets
set assignment_library_order = (render_config->>'assignmentLibraryOrder')::integer
where preset_kind = 'assignment'
  and assignment_library_order is null
  and coalesce(render_config->>'assignmentLibraryOrder', '') ~ '^-?[0-9]+$';

create index if not exists idx_pb_export_presets_assignment_library_order
  on public.pb_export_presets (
    academy_id,
    preset_kind,
    assignment_library_order asc nulls last,
    updated_at desc
  )
  where preset_kind = 'assignment';
