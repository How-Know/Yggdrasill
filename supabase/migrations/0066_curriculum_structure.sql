-- 커리큘럼 구조 테이블 생성

-- 1. 교육과정 테이블 (2022 개정, 2015 개정 등)
create table if not exists curriculum (
  id uuid primary key default gen_random_uuid(),
  name text not null unique, -- '2022 개정', '2015 개정' 등
  description text,
  is_active boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 2. 학년/과목 테이블 (중1-1, 중1-2, 공통수학1 등)
create table if not exists grade (
  id uuid primary key default gen_random_uuid(),
  curriculum_id uuid not null references curriculum(id) on delete cascade,
  school_level text not null check (school_level in ('중', '고')), -- 중학교/고등학교
  name text not null, -- '1-1', '1-2', '공통수학1' 등
  display_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique(curriculum_id, school_level, name)
);

-- 3. 대단원 테이블
create table if not exists chapter (
  id uuid primary key default gen_random_uuid(),
  grade_id uuid not null references grade(id) on delete cascade,
  name text not null, -- '소인수분해', '정수와 유리수' 등
  description text,
  display_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique(grade_id, name)
);

-- 4. 소단원 테이블
create table if not exists section (
  id uuid primary key default gen_random_uuid(),
  chapter_id uuid not null references chapter(id) on delete cascade,
  name text not null, -- '소인수분해의 뜻', '거듭제곱' 등
  description text,
  display_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique(chapter_id, name)
);

-- 인덱스 생성
create index if not exists idx_grade_curriculum on grade(curriculum_id);
create index if not exists idx_chapter_grade on chapter(grade_id);
create index if not exists idx_section_chapter on section(chapter_id);

-- updated_at 자동 업데이트 트리거
create trigger set_curriculum_updated_at before update on curriculum
  for each row execute function set_updated_at();

create trigger set_grade_updated_at before update on grade
  for each row execute function set_updated_at();

create trigger set_chapter_updated_at before update on chapter
  for each row execute function set_updated_at();

create trigger set_section_updated_at before update on section
  for each row execute function set_updated_at();

-- RLS 정책 (인증된 사용자만 읽기/쓰기 가능)
alter table curriculum enable row level security;
alter table grade enable row level security;
alter table chapter enable row level security;
alter table section enable row level security;

-- 읽기 정책
create policy "인증된 사용자는 교육과정을 조회할 수 있음"
  on curriculum for select
  to authenticated
  using (true);

create policy "인증된 사용자는 학년을 조회할 수 있음"
  on grade for select
  to authenticated
  using (true);

create policy "인증된 사용자는 대단원을 조회할 수 있음"
  on chapter for select
  to authenticated
  using (true);

create policy "인증된 사용자는 소단원을 조회할 수 있음"
  on section for select
  to authenticated
  using (true);

-- 쓰기 정책 (관리자만 가능 - 추후 관리자 체크 로직 추가)
create policy "인증된 사용자는 교육과정을 관리할 수 있음"
  on curriculum for all
  to authenticated
  using (true)
  with check (true);

create policy "인증된 사용자는 학년을 관리할 수 있음"
  on grade for all
  to authenticated
  using (true)
  with check (true);

create policy "인증된 사용자는 대단원을 관리할 수 있음"
  on chapter for all
  to authenticated
  using (true)
  with check (true);

create policy "인증된 사용자는 소단원을 관리할 수 있음"
  on section for all
  to authenticated
  using (true)
  with check (true);

-- 샘플 데이터 삽입 (2022 개정 중1-1)
insert into curriculum (name, description) values 
  ('2022 개정', '2022 개정 교육과정'),
  ('2015 개정', '2015 개정 교육과정');

-- 중1-1 학기 추가
insert into grade (curriculum_id, school_level, name, display_order)
select id, '중', '1-1', 0
from curriculum where name = '2022 개정';

-- 대단원 추가
insert into chapter (grade_id, name, display_order)
select g.id, '소인수분해', 1
from grade g
join curriculum c on g.curriculum_id = c.id
where c.name = '2022 개정' and g.name = '1-1';

insert into chapter (grade_id, name, display_order)
select g.id, '정수와 유리수', 2
from grade g
join curriculum c on g.curriculum_id = c.id
where c.name = '2022 개정' and g.name = '1-1';

insert into chapter (grade_id, name, display_order)
select g.id, '문자와 식', 3
from grade g
join curriculum c on g.curriculum_id = c.id
where c.name = '2022 개정' and g.name = '1-1';

insert into chapter (grade_id, name, display_order)
select g.id, '좌표평면과 그래프', 4
from grade g
join curriculum c on g.curriculum_id = c.id
where c.name = '2022 개정' and g.name = '1-1';

-- 소단원 샘플 (소인수분해)
insert into section (chapter_id, name, display_order)
select ch.id, '소인수분해의 뜻', 1
from chapter ch
join grade g on ch.grade_id = g.id
join curriculum c on g.curriculum_id = c.id
where c.name = '2022 개정' and g.name = '1-1' and ch.name = '소인수분해';

insert into section (chapter_id, name, display_order)
select ch.id, '거듭제곱', 2
from chapter ch
join grade g on ch.grade_id = g.id
join curriculum c on g.curriculum_id = c.id
where c.name = '2022 개정' and g.name = '1-1' and ch.name = '소인수분해';

insert into section (chapter_id, name, display_order)
select ch.id, '최대공약수와 최소공배수', 3
from chapter ch
join grade g on ch.grade_id = g.id
join curriculum c on g.curriculum_id = c.id
where c.name = '2022 개정' and g.name = '1-1' and ch.name = '소인수분해';


