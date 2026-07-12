-- _student_grading_mode: \alpha 같은 그리스 문자 LaTeX 명령이 라벨로 쓰인
-- 복수 라벨 답(α=…, β=…)을 self로 분류하도록 전처리 추가.
-- (Edge Function grading.ts의 gradingMode()와 동일 로직 유지)

create or replace function public._student_grading_mode(
  p_kind text,
  p_text text
) returns text
language plpgsql immutable as $$
declare
  t text := coalesce(p_text, '');
  labels text[];
begin
  if p_kind = 'objective' then return 'auto'; end if;
  if p_kind = 'image' then return 'self'; end if;
  -- 그리스 문자 LaTeX 명령을 실제 문자로 (라벨 감지용)
  t := replace(t, '\alpha', 'α'); t := replace(t, '\beta', 'β');
  t := replace(t, '\gamma', 'γ'); t := replace(t, '\delta', 'δ');
  t := replace(t, '\theta', 'θ'); t := replace(t, '\lambda', 'λ');
  if btrim(t) = '' then return 'self'; end if;

  if t ~ '(^|\s)\(\s*\d\s*\)\s*\S' then return 'self'; end if;      -- 세트형 (1)(2)
  if t ~ '\((가|나|다|라|마|바|사)\)' then return 'self'; end if;    -- 빈칸 채우기
  if position('\begin' in t) > 0 then return 'self'; end if;         -- 연립/행렬
  if t ~ '풀이\s*\d+\s*쪽' then return 'self'; end if;                -- 풀이 참조

  -- 복수 라벨: '=' 또는 ':' 앞의 라벨(문자로 시작)이 2종 이상
  labels := array(
    select distinct btrim(m[1])
    from regexp_matches(t, '(?:^|[,;\s(])\s*([A-Za-zα-ω가-힣][A-Za-z0-9α-ω가-힣의 ]{0,15}?)\s*[:=]', 'g') m
    where btrim(m[1]) !~ '^\d+$'
  );
  if coalesce(array_length(labels, 1), 0) >= 2 then return 'self'; end if;

  return 'auto';
end; $$;
