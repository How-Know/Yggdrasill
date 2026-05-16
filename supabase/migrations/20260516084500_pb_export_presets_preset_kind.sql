alter table public.pb_export_presets
  add column if not exists preset_kind text not null default 'settings';

update public.pb_export_presets
set preset_kind = 'settings'
where preset_kind is null or trim(preset_kind) = '';

alter table public.pb_export_presets
  alter column preset_kind set default 'settings',
  alter column preset_kind set not null;

alter table public.pb_export_presets
  drop constraint if exists pb_export_presets_preset_kind_chk;

alter table public.pb_export_presets
  add constraint pb_export_presets_preset_kind_chk
  check (preset_kind in ('settings', 'assignment'));

create index if not exists idx_pb_export_presets_academy_kind_updated
  on public.pb_export_presets (academy_id, preset_kind, updated_at desc);
