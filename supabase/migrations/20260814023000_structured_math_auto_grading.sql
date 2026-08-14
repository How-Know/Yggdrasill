-- MyScript가 선형화할 수 있는 연립방정식·행렬 환경은 자동 채점한다.
-- Edge Function grading.ts의 gradingMode()와 동일 규칙을 유지한다.

create or replace function public._student_grading_mode(
  p_kind text,
  p_text text
) returns text
language plpgsql immutable as $$
declare
  t text := coalesce(p_text, '');
  labels text[];
  environments text[];
begin
  if p_kind = 'objective' then return 'auto'; end if;
  if p_kind = 'image' then return 'self'; end if;

  t := replace(t, '\alpha', 'α'); t := replace(t, '\beta', 'β');
  t := replace(t, '\gamma', 'γ'); t := replace(t, '\delta', 'δ');
  t := replace(t, '\theta', 'θ'); t := replace(t, '\lambda', 'λ');
  if btrim(t) = '' then return 'self'; end if;

  if t ~ '(^|\s)\(\s*\d\s*\)\s*\S' then return 'self'; end if;
  if t ~ '\((가|나|다|라|마|바|사)\)' then return 'self'; end if;

  if position('\begin' in t) > 0 then
    select array_agg(m[1])
      into environments
    from regexp_matches(t, '\\begin\{([^{}]+)\}', 'g') m;

    if coalesce(cardinality(environments), 0) = 0
       or not (
         environments <@ array[
           'cases', 'matrix', 'pmatrix', 'bmatrix', 'Bmatrix',
           'vmatrix', 'Vmatrix', 'array'
         ]::text[]
       )
       or t ~ '[가-힣]' then
      return 'self';
    end if;
    return 'auto';
  end if;

  if t ~ '풀이\s*\d+\s*쪽' then return 'self'; end if;

  labels := array(
    select distinct btrim(m[1])
    from regexp_matches(
      t,
      '(?:^|[,;\s(])\s*([A-Za-zα-ω가-힣][A-Za-z0-9α-ω가-힣의 ]{0,15}?)\s*[:=]',
      'g'
    ) m
    where btrim(m[1]) !~ '^\d+$'
  );
  if coalesce(array_length(labels, 1), 0) >= 2 then return 'self'; end if;

  return 'auto';
end; $$;
