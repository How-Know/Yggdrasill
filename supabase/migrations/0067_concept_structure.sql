-- 개념 구조 테이블 생성

-- 1. 개념 그룹 (구분선)
create table if not exists concept_group (
  id uuid primary key default gen_random_uuid(),
  section_id uuid not null references section(id) on delete cascade,
  name text, -- 구분선 이름 (선택사항)
  display_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 2. 개념
create table if not exists concept (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references concept_group(id) on delete cascade,
  name text not null, -- 개념 이름
  color text default '#4A9EFF', -- 칩 색상
  tags text[] default '{}', -- 태그 배열
  display_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 인덱스 생성
create index if not exists idx_concept_group_section on concept_group(section_id);
create index if not exists idx_concept_group on concept(group_id);

-- updated_at 자동 업데이트 트리거
create trigger set_concept_group_updated_at before update on concept_group
  for each row execute function set_updated_at();

create trigger set_concept_updated_at before update on concept
  for each row execute function set_updated_at();

-- RLS 정책
alter table concept_group enable row level security;
alter table concept enable row level security;

-- 읽기 정책
create policy "인증된 사용자는 개념 그룹을 조회할 수 있음"
  on concept_group for select
  to authenticated
  using (true);

create policy "인증된 사용자는 개념을 조회할 수 있음"
  on concept for select
  to authenticated
  using (true);

-- 쓰기 정책
create policy "인증된 사용자는 개념 그룹을 관리할 수 있음"
  on concept_group for all
  to authenticated
  using (true)
  with check (true);

create policy "인증된 사용자는 개념을 관리할 수 있음"
  on concept for all
  to authenticated
  using (true)
  with check (true);


