-- Ensure function search_path is fixed to a safe value
alter function public.set_updated_at() set search_path = public;








