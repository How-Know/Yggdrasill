-- 20260928100100: platform_config 잠금
-- 학생 계정도 authenticated 세션을 받기 때문에 "로그인 사용자 전체 읽기·쓰기" 정책으로는
-- OpenAI 키가 누구에게나 노출될 수 있었다. 키는 Edge Function 비밀값(OPENAI_API_KEY)으로만 관리한다.

delete from public.platform_config where config_key = 'openai_api_key';

drop policy if exists "Authenticated users can read platform config" on public.platform_config;
drop policy if exists "Authenticated users can upsert platform config" on public.platform_config;
drop policy if exists "Super admins can read platform config" on public.platform_config;
drop policy if exists "Super admins can upsert platform config" on public.platform_config;

drop policy if exists platform_config_superadmin_all on public.platform_config;
create policy platform_config_superadmin_all on public.platform_config
  for all to authenticated
  using ((select public.is_superadmin()))
  with check ((select public.is_superadmin()));

comment on table public.platform_config is 'Platform-wide settings (superadmin only). API keys belong in Edge Function secrets, not here.';
