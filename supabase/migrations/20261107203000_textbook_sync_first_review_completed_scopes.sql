-- 20261107203000:
-- 수력충전 1-2 1단원('0. 기본 도형 › 0. 기본 도형', 소단원 9개: 0/0/W0 ~ 0/0/W8) 및
-- 문항이 모두 승인(math_status = 'approved' and quality_status = 'approved')된 소단원들의
-- textbook_metadata.payload.auto_analyzed_scopes 를 동기화하여
-- 단원 트리와 마이그레이션 진행률에서 9/90(소단원 9개 모두 '1차 검수완료')로 정확히 표시되도록 보정한다.

do $$
declare
  v_now text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  v_scopes jsonb;
begin
  select coalesce(tm.payload -> 'auto_analyzed_scopes', '{}'::jsonb)
    into v_scopes
    from public.textbook_metadata tm
   where tm.book_id = '09d8c890-a69f-4814-b57d-e16b0bf88432'::uuid
     and tm.grade_label = '1-2'
   limit 1;

  if v_scopes is not null then
    v_scopes := v_scopes
      || jsonb_build_object(
           '0/0/W0', coalesce(v_scopes ->> '0/0/W0', v_now),
           '0/0/W1', coalesce(v_scopes ->> '0/0/W1', v_now),
           '0/0/W2', coalesce(v_scopes ->> '0/0/W2', v_now),
           '0/0/W3', coalesce(v_scopes ->> '0/0/W3', v_now),
           '0/0/W4', coalesce(v_scopes ->> '0/0/W4', v_now),
           '0/0/W5', coalesce(v_scopes ->> '0/0/W5', v_now),
           '0/0/W6', coalesce(v_scopes ->> '0/0/W6', v_now),
           '0/0/W7', coalesce(v_scopes ->> '0/0/W7', v_now),
           '0/0/W8', coalesce(v_scopes ->> '0/0/W8', v_now)
         );

    update public.textbook_metadata tm
       set payload = jsonb_set(coalesce(tm.payload, '{}'::jsonb), '{auto_analyzed_scopes}', v_scopes),
           updated_at = now()
     where tm.book_id = '09d8c890-a69f-4814-b57d-e16b0bf88432'::uuid
       and tm.grade_label = '1-2';
  end if;
end;
$$;
