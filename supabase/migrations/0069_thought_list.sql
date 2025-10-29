-- 사고 폴더 테이블 (중첩 가능한 트리 구조)
CREATE TABLE thought_folder (
  id TEXT PRIMARY KEY DEFAULT uuid_generate_v4(),
  parent_id TEXT REFERENCES thought_folder(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  display_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 사고 카드 테이블
CREATE TABLE thought_card (
  id TEXT PRIMARY KEY DEFAULT uuid_generate_v4(),
  folder_id TEXT REFERENCES thought_folder(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  content TEXT,
  display_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스
CREATE INDEX idx_thought_folder_parent ON thought_folder(parent_id);
CREATE INDEX idx_thought_card_folder ON thought_card(folder_id);

