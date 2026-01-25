-- Allow questions.trait to be nullable (pre-survey support)

alter table public.questions
  alter column trait drop not null;

alter table public.questions
  drop constraint if exists questions_trait_check;

alter table public.questions
  add constraint questions_trait_check
  check (trait is null or trait in ('D','I','A','C','N','L','S','P'));
