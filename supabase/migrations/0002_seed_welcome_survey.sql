-- Seed: welcome survey with single short_text question
insert into public.surveys (slug, title, description, is_public, is_active)
values ('welcome', '첫 설문', '자유롭게 의견을 남겨주세요.', true, true)
on conflict (slug) do nothing;

insert into public.survey_questions (survey_id, question_type, question_text, is_required, order_index)
select id, 'short_text', '한 줄 의견을 남겨주세요.', true, 1
from public.surveys where slug = 'welcome'
on conflict do nothing;




