-- 문제은행 문항의 본문·공통 발문·선지·그림이 바뀌면 그 문항의 V2 렌더 검수를 다시 하도록 검수 시각을 지운다.
-- 판정 내용(render_checks)은 다시 대조할 때까지 남겨 둔다.

create index if not exists textbook_problem_crops_pb_question_uid_idx
  on public.textbook_problem_crops (academy_id, pb_question_uid)
  where pb_question_uid is not null;

create or replace function public.textbook_question_reset_render_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (old.stem, old.choices, old.figure_refs,
      old.meta #> '{set_model,common_stem}', old.meta -> 'figure_assets', old.meta -> 'figure_layout')
     is distinct from
     (new.stem, new.choices, new.figure_refs,
      new.meta #> '{set_model,common_stem}', new.meta -> 'figure_assets', new.meta -> 'figure_layout') then
    update public.textbook_problem_analyses an
       set render_checked_at = null
      from public.textbook_problem_crops c
     where c.academy_id = new.academy_id
       and c.pb_question_uid = new.question_uid
       and an.crop_id = c.id
       and an.render_checked_at is not null;
  end if;
  return new;
end;
$$;

drop trigger if exists textbook_question_reset_render_check on public.pb_questions;
create trigger textbook_question_reset_render_check
  after update on public.pb_questions
  for each row execute function public.textbook_question_reset_render_check();

-- 이상 판정이 남아 있는데 그 뒤에 문항이 고쳐진 경우는 지금 데이터로 다시 판정받게 한다.
update public.textbook_problem_analyses an
   set render_checked_at = null
  from public.textbook_problem_crops c
  join public.pb_questions q
    on q.academy_id = c.academy_id and q.question_uid = c.pb_question_uid
 where an.crop_id = c.id
   and an.render_checked_at is not null
   and coalesce(an.render_checks ->> 'issue_kind', 'none') <> 'none'
   and q.updated_at > an.render_checked_at + interval '1 second';
