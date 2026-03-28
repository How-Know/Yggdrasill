-- 학습 앱 문제은행 문항 순서(필터 스코프별) 저장 테이블

create table if not exists public.learning_problem_bank_question_orders (
  academy_id uuid not null references public.academies(id) on delete cascade,
  scope_key text not null,
  question_id uuid not null references public.pb_questions(id) on delete cascade,
  order_index integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (academy_id, scope_key, question_id)
);

create index if not exists idx_learning_pb_question_orders_scope
  on public.learning_problem_bank_question_orders (academy_id, scope_key, order_index);

drop trigger if exists trg_learning_pb_question_orders_updated_at
  on public.learning_problem_bank_question_orders;
create trigger trg_learning_pb_question_orders_updated_at
before update on public.learning_problem_bank_question_orders
for each row execute function public.set_updated_at();

alter table public.learning_problem_bank_question_orders enable row level security;

drop policy if exists "Read learning_problem_bank_question_orders"
  on public.learning_problem_bank_question_orders;
create policy "Read learning_problem_bank_question_orders"
on public.learning_problem_bank_question_orders for select
to authenticated
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = learning_problem_bank_question_orders.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists "Manage learning_problem_bank_question_orders"
  on public.learning_problem_bank_question_orders;
create policy "Manage learning_problem_bank_question_orders"
on public.learning_problem_bank_question_orders for all
to authenticated
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = learning_problem_bank_question_orders.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = learning_problem_bank_question_orders.academy_id
      and m.user_id = auth.uid()
  )
);
