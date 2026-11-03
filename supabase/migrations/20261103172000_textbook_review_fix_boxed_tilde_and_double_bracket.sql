-- 20261103172000: 문항검수 — \boxed{~~} 빈칸 물결표 노출 및 [[공백:N]] 이중 대괄호 마크업 정리

do $$
declare
  v_fixed int;
begin
  with upd as (
    update public.pb_questions q
       set stem = regexp_replace(
             regexp_replace(
               q.stem,
               E'\\\\boxed\\s*\\{\\s*~+\\s*\\}',
               'box{~~}',
               'g'
             ),
             E'\\[\\s*\\[\\s*공백\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*\\]\\s*\\]',
             '[공백:\1]',
             'g'
           ),
           updated_at = now()
     where q.stem ~ E'\\\\boxed\\s*\\{\\s*~+\\s*\\}'
        or q.stem ~ E'\\[\\s*\\[\\s*공백\\s*:\\s*[0-9]+(?:\\.[0-9]+)?\\s*\\]\\s*\\]'
    returning q.id
  )
  select count(*) into v_fixed from upd;

  raise notice '[MARKUP_FIXED] pb_questions updated=%', v_fixed;
end;
$$;
