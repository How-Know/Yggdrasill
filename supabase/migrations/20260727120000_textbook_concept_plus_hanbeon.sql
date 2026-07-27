-- 20260727120000: 개념+유형 "한 번 더 연습"(sub_key 'F') 지원
--
-- 정답·해설 파일을 확인해 보니 "한 번 더 연습"은 쏙쏙 개념 익히기 안의 배지가
-- 아니라 자기 지면을 가진 독립 코너였다. 해설 기준 "한 번 더 연습 P.47"이 1~4번,
-- 바로 다음 "쏙쏙 개념 익히기 P.48"이 다시 1~6번이라 같은 소단원 안에서 번호가
-- 겹친다. 그래서 개념원리 특강(E)과 같은 방식으로 전용 슬롯 'F'에 분리 저장한다.
-- (쏙쏙 문항에 붙는 "한 번 더 +1" 배지는 이것과 다른, 같은 번호를 잇는 쌍둥이
--  문항 표시이므로 여전히 C 안에 남는다.)
--
-- sub_index 규칙은 A·B·C와 같이 소단원 순번을 쓴다.

alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_sub_key_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_sub_key_chk
  check (sub_key in ('A', 'B', 'C', 'D', 'E', 'F'));

alter table public.textbook_pb_extract_runs
  drop constraint if exists textbook_pb_extract_runs_sub_key_chk;
alter table public.textbook_pb_extract_runs
  add constraint textbook_pb_extract_runs_sub_key_chk
  check (sub_key in ('A', 'B', 'C', 'D', 'E', 'F'));

-- 탄탄 단원 다지기는 문항 번호 위 원 세 개로 난이도(하/중/상)를 표기하고,
-- 그와 **별개로** 노란 별 "중요" 표시가 붙는다. 난이도는 기존 label 컬럼을
-- 그대로 쓰고, 중요 표시만 전용 플래그로 둔다.
alter table public.textbook_problem_crops
  add column if not exists is_important boolean not null default false;

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('gaeyu', 'C', '쏙쏙 개념 익히기', 2, 'STEP1 소단원 마무리'),
  ('gaeyu', 'F', '한 번 더 연습', 5, '쏙쏙 개념 익히기 직전에 불규칙하게 붙는 연습 지면')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;
