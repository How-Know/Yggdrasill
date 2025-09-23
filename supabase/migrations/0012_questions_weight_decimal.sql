-- Change questions.weight from integer to numeric(10,2)
alter table public.questions
  alter column weight type numeric(10,2) using weight::numeric,
  alter column weight set default 1.00;




