-- 20260722153000: 세트형 파트 상한 8 → 12
--
-- 개념원리 '확인 체크' 등은 (1)~(10)처럼 파트가 8개를 넘는 경우가 있어
-- 기존 상한(8)에서 세트형으로 인식되지 못했다. 상한을 12로 올린다.
-- (Edge Function grading.ts / 학습앱 / 게이트웨이 파서도 동일하게 12로 맞춤)

create or replace function public._split_set_answer_parts(
  p_text text
) returns jsonb
language plpgsql immutable as $$
declare
  t text := btrim(coalesce(p_text, ''));
  n int;
  i int := 1;
  expected int := 1;
  content_start int := null;
  parts jsonb := '[]'::jsonb;
  head text;
  mnum text;
  mtext text;
  prevch text;
  part_text text;
begin
  if t = '' then return null; end if;
  n := length(t);

  while i <= n loop
    head := substring(t from i);
    mnum := substring(head from '^[(（]\s*([0-9]{1,2})\s*[)）]');
    if mnum is not null and mnum::int = expected then
      prevch := case when i = 1 then ' ' else substring(t, i - 1, 1) end;
      if prevch ~ '\s' then
        mtext := substring(head from '^[(（]\s*[0-9]{1,2}\s*[)）]');
        if expected = 1 then
          -- 첫 마커: 마커 앞에는 내용이 없어야 세트형으로 본다
          if btrim(substring(t, 1, i - 1)) = '' then
            content_start := i + length(mtext);
            expected := 2;
            i := i + length(mtext);
            continue;
          end if;
        else
          part_text := btrim(substring(t, content_start, i - content_start));
          if part_text <> '' then
            parts := parts || jsonb_build_object(
              'key', '(' || (expected - 1)::text || ')',
              'text', part_text
            );
            content_start := i + length(mtext);
            expected := expected + 1;
            i := i + length(mtext);
            continue;
          end if;
          -- 내용이 비면 이 후보는 마커가 아니라 이전 파트의 내용
        end if;
      end if;
    end if;
    i := i + 1;
  end loop;

  if expected < 3 then return null; end if; -- 파트 2개 미만
  part_text := btrim(substring(t from content_start));
  if part_text = '' then return null; end if;
  parts := parts || jsonb_build_object(
    'key', '(' || (expected - 1)::text || ')',
    'text', part_text
  );
  if jsonb_array_length(parts) > 12 then return null; end if;
  return parts;
end; $$;
