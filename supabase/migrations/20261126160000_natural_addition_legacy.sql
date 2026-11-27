-- 자연수 덧셈 10개 유형의 지금 비용·예상 초를 비교용으로 남긴다.
-- arithmetic_primitives.unit_score 와 est_seconds, 문항 점수는 바꾸지 않는다.

create table if not exists public.arithmetic_addition_legacy (
  code text primary key,
  unit_score numeric(6, 2) not null,
  est_seconds numeric(5, 1) not null,
  captured_at timestamptz not null default now()
);

insert into public.arithmetic_addition_legacy (code, unit_score, est_seconds)
select p.code, p.unit_score, p.est_seconds
from public.arithmetic_primitives p
where p.code in (
  'nat_add_1d_1d_nc',
  'nat_add_1d_1d_c1',
  'nat_add_2d_1d_nc',
  'nat_add_2d_1d_c1',
  'nat_add_2d_1d_c2',
  'nat_add_2d_2d_nc',
  'nat_add_2d_2d_c1',
  'nat_add_2d_2d_c2',
  'nat_add_3d_23d_c01',
  'nat_add_3d_3d_c2p'
)
on conflict (code) do nothing;

alter table public.arithmetic_addition_legacy enable row level security;
revoke all on public.arithmetic_addition_legacy from anon, authenticated;

create or replace function public.arithmetic_addition_legacy_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_addition_forbidden';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'code', code,
      'unit_score', unit_score,
      'est_seconds', est_seconds
    ) order by code)
    from public.arithmetic_addition_legacy
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.arithmetic_addition_legacy_list() from public, anon;
grant execute on function public.arithmetic_addition_legacy_list() to authenticated;
