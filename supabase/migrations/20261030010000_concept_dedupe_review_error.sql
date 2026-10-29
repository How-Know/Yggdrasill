-- 개념 검수 오류로 생긴 중복 기초 개념 26개를 유형 연결과 함께 지운다(한 번만).
-- 근거: Think 결정 「검수 오류 중복 26개·유형 연결 동시 삭제 예외」(64c1ca7f, 2026-10-29 승인).
-- 「개념 삭제와 검토 기록 보존 기준」의 예외는 이 목록에만 쓴다. 다른 개념의 삭제 보호는 그대로다.
-- 지우기 직전에 조건을 다시 확인하고, 하나라도 어긋나면 아무것도 지우지 않고 멈춘다.
--   2026-10-26 이후 생성 · 붙은 것은 유형 연결뿐 · 검토 기록의 비교·비교 필요에 인용 안 됨 · 자기 검토 기록 없음
--   · 검수 목록에 없음 · 승인 대기 카드에 없음 · 보류 위치가 기다리는 생성 카드의 결과가 아님 · 이름별 남는 개념 있음.

do $$
declare
  v_ids uuid[];
  v_names text[];
  r record;
  v_att jsonb;
  v_n integer;
begin
  create temp table dedupe_target (id uuid primary key, name text not null) on commit drop;
  insert into dedupe_target (id, name) values
    ('917ffbb8-72fb-41ec-a906-ecd4503fd9a2', '각의 뜻과 크기'),
    ('2143bc2d-d20d-447a-8620-fe889c0e7507', '각의 뜻과 크기'),
    ('7a921946-fc45-4d23-986d-0d2001e6ae0d', '각의 뜻과 크기'),
    ('fd06107a-9ab2-4004-9036-671f7b71ff83', '각의 뜻과 크기'),
    ('341da8a3-6194-4c03-8f24-a17fb5d84474', '각의 뜻과 크기'),
    ('ca2450c1-32df-40be-a278-d890af99110e', '각의 뜻과 크기'),
    ('f3a2542f-4e51-4d45-9abe-0f74d174c6c0', '각의 뜻과 크기'),
    ('a6c039e5-7738-42b3-b430-a3b2921940b2', '길이와 넓이의 뜻'),
    ('3c66ddcb-66e7-466b-980c-99287362ef44', '다각형의 뜻과 구성 요소'),
    ('7ce56c1c-1479-435e-807a-d886659833d9', '다각형의 뜻과 구성 요소'),
    ('430ba7d2-ccd8-4607-9b72-92d01f1ad217', '다각형의 뜻과 구성 요소'),
    ('eb9bc33b-c606-4d21-8518-a35044267584', '다각형의 뜻과 구성 요소'),
    ('f5cf4a05-416b-4b54-865e-2914d3f15697', '다각형의 뜻과 구성 요소'),
    ('d6eacfad-7d88-4fe3-ba79-91a351aa4c84', '다각형의 뜻과 구성 요소'),
    ('98184b7f-aecc-43eb-b23e-07c8c8efd7f4', '다각형의 뜻과 구성 요소'),
    ('21aefc54-600c-421e-aee1-c4d683226aed', '도형을 나누거나 옮겨 넓이 구하기'),
    ('dde4ea2c-f7fc-443c-937d-808e2a0cfb84', '소수에 10, 100, 1000 곱하기'),
    ('d6af0b64-2816-4940-acfc-37eb9d5c0c90', '이상·이하·초과·미만'),
    ('dd62d9a1-113e-4be5-b843-3c0116db4b37', '이상·이하·초과·미만'),
    ('110e34b7-0a7a-4277-9ffd-1b3b367c1128', '입체도형의 면·모서리·꼭짓점'),
    ('46a4307f-17a4-411a-ba0c-c329f391ea79', '입체도형의 면·모서리·꼭짓점'),
    ('b6eabf1d-ea9c-428a-84ca-f977143908d8', '입체도형의 면·모서리·꼭짓점'),
    ('90c6186a-fd7b-49ee-bbdd-00a7aa1ce4fa', '입체도형의 면·모서리·꼭짓점'),
    ('c169f612-4059-4c77-8ca8-b390a9a5fdd0', '입체도형의 면·모서리·꼭짓점'),
    ('828c23c5-72f0-404d-8b0f-3ee8e79ca43d', '입체도형의 면·모서리·꼭짓점'),
    ('28d85c54-e895-4c3a-86f7-165c0fc9a3b1', '입체도형의 면·모서리·꼭짓점');

  select array_agg(id) into v_ids from dedupe_target;
  if cardinality(v_ids) <> 26 then
    raise exception 'dedupe_count_mismatch: %', cardinality(v_ids);
  end if;

  -- 이름별 삭제 수(승인된 목록 그대로)
  for r in
    select * from (values
      ('각의 뜻과 크기', 7), ('다각형의 뜻과 구성 요소', 7), ('입체도형의 면·모서리·꼭짓점', 7),
      ('이상·이하·초과·미만', 2), ('길이와 넓이의 뜻', 1), ('도형을 나누거나 옮겨 넓이 구하기', 1),
      ('소수에 10, 100, 1000 곱하기', 1)
    ) as e(name, n)
  loop
    select count(*) into v_n from dedupe_target where name = r.name;
    if v_n <> r.n then
      raise exception 'dedupe_name_count_mismatch: % % <> %', r.name, v_n, r.n;
    end if;
    select count(*) into v_n
      from public.concepts c
     where c.name = r.name and c.id <> all (v_ids);
    if v_n < 1 then
      raise exception 'dedupe_no_keeper: %', r.name;
    end if;
  end loop;

  for r in
    select t.id, t.name, c.name as cur_name, c.created_at
      from dedupe_target t
      left join public.concepts c on c.id = t.id
  loop
    if r.cur_name is null then
      raise exception 'dedupe_missing: %', r.id;
    end if;
    if r.cur_name <> r.name then
      raise exception 'dedupe_renamed: % (%)', r.id, r.cur_name;
    end if;
    if r.created_at < '2026-10-26'::timestamptz then
      raise exception 'dedupe_too_old: %', r.id;
    end if;
    v_att := public.concept_attachments(r.id);
    if (v_att ->> 'total')::integer <> (v_att ->> 'type_link')::integer then
      raise exception 'dedupe_attached: % %', r.id, v_att;
    end if;
    if exists (select 1 from public.concept_quality_reviews q where q.concept_id = r.id) then
      raise exception 'dedupe_own_review: %', r.id;
    end if;
    if exists (
      select 1 from public.concept_quality_reviews q
        cross join lateral jsonb_array_elements(coalesce(q.compared, '[]'::jsonb) || coalesce(q.to_compare, '[]'::jsonb)) e
       where public.course_think_uuid(e ->> 'id') = r.id
    ) then
      raise exception 'dedupe_cited: %', r.id;
    end if;
    if exists (select 1 from public.concept_review_walks w where r.id = any (w.concept_ids)) then
      raise exception 'dedupe_in_walk: %', r.id;
    end if;
    if exists (
      select 1 from public.ai_actions a
       where a.status = 'proposed' and a.payload::text like '%' || r.id::text || '%'
    ) then
      raise exception 'dedupe_open_card: %', r.id;
    end if;
    if exists (
      select 1 from public.concept_review_job_items i
        join public.ai_actions a on i.held_fixes::text like '%' || a.id::text || '%'
       where i.state = 'held'
         and (a.result::text like '%' || r.id::text || '%' or a.payload::text like '%' || r.id::text || '%')
    ) then
      raise exception 'dedupe_held_dependency: %', r.id;
    end if;
  end loop;

  delete from public.concept_type_links where concept_id = any (v_ids);
  delete from public.concepts where id = any (v_ids);
  get diagnostics v_n = row_count;
  if v_n <> 26 then
    raise exception 'dedupe_deleted_mismatch: %', v_n;
  end if;
end;
$$;
