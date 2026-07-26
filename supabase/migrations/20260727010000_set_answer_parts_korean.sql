-- 20260727010000: 세트형 파트 분리에 (가)(나)(다) 한글 마커 지원
--
-- 개념원리 '개념원리 익히기'류 빈칸 채우기 문항은 정답이 "(가) 유한 (나) 무한"
-- 형태라 기존에는 세트형으로 분리되지 못하고 셀프 채점으로만 처리됐다.
-- 첫 마커가 (1)이면 숫자 시퀀스, (가)면 가나다 시퀀스로 파트를 분리한다.
-- (Edge Function grading.ts / 학습앱 / 게이트웨이 파서도 동일 규칙으로 수정)

create or replace function public._split_set_answer_parts(
  p_text text
) returns jsonb
language plpgsql immutable as $$
declare
  t text := btrim(coalesce(p_text, ''));
  kor_keys text[] := array['가','나','다','라','마','바','사','아','자','차','카','타'];
  is_kor boolean := false;
  n int;
  i int := 1;
  expected int := 1;
  content_start int := null;
  parts jsonb := '[]'::jsonb;
  head text;
  mnum text;
  mkor text;
  mtext text;
  matched_len int;
  prevch text;
  part_text text;
  part_key text;
begin
  if t = '' then return null; end if;
  n := length(t);

  while i <= n loop
    head := substring(t from i);
    matched_len := 0;
    if expected = 1 then
      -- 첫 마커: (1)이면 숫자 모드, (가)면 한글 모드
      mnum := substring(head from '^[(（]\s*([0-9]{1,2})\s*[)）]');
      if mnum is not null and mnum::int = 1 then
        mtext := substring(head from '^[(（]\s*[0-9]{1,2}\s*[)）]');
        matched_len := length(mtext);
        is_kor := false;
      else
        mkor := substring(head from '^[(（]\s*([가-힣])\s*[)）]');
        if mkor is not null and mkor = kor_keys[1] then
          mtext := substring(head from '^[(（]\s*[가-힣]\s*[)）]');
          matched_len := length(mtext);
          is_kor := true;
        end if;
      end if;
    elsif is_kor then
      mkor := substring(head from '^[(（]\s*([가-힣])\s*[)）]');
      if mkor is not null
         and expected <= array_length(kor_keys, 1)
         and mkor = kor_keys[expected] then
        mtext := substring(head from '^[(（]\s*[가-힣]\s*[)）]');
        matched_len := length(mtext);
      end if;
    else
      mnum := substring(head from '^[(（]\s*([0-9]{1,2})\s*[)）]');
      if mnum is not null and mnum::int = expected then
        mtext := substring(head from '^[(（]\s*[0-9]{1,2}\s*[)）]');
        matched_len := length(mtext);
      end if;
    end if;

    if matched_len > 0 then
      prevch := case when i = 1 then ' ' else substring(t, i - 1, 1) end;
      if prevch ~ '\s' then
        if expected = 1 then
          -- 첫 마커: 마커 앞에는 내용이 없어야 세트형으로 본다
          if btrim(substring(t, 1, i - 1)) = '' then
            content_start := i + matched_len;
            expected := 2;
            i := i + matched_len;
            continue;
          end if;
        else
          part_text := btrim(substring(t, content_start, i - content_start));
          if part_text <> '' then
            part_key := case when is_kor
              then '(' || kor_keys[expected - 1] || ')'
              else '(' || (expected - 1)::text || ')' end;
            parts := parts || jsonb_build_object(
              'key', part_key,
              'text', part_text
            );
            content_start := i + matched_len;
            expected := expected + 1;
            i := i + matched_len;
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
  part_key := case when is_kor
    then '(' || kor_keys[expected - 1] || ')'
    else '(' || (expected - 1)::text || ')' end;
  parts := parts || jsonb_build_object(
    'key', part_key,
    'text', part_text
  );
  if jsonb_array_length(parts) > 12 then return null; end if;
  return parts;
end; $$;
