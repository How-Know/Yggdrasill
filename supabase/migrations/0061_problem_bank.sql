-- 0061: 문제은행 테이블 및 Storage 버킷 생성

-- Storage 버킷 생성 (problem-images)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'problem-images',
  'problem-images',
  true,
  10485760, -- 10MB
  ARRAY['image/png', 'image/jpeg', 'image/jpg']
)
ON CONFLICT (id) DO NOTHING;

-- 문제은행 테이블 생성
CREATE TABLE IF NOT EXISTS problem_bank (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  academy_id UUID NOT NULL REFERENCES academies(id) ON DELETE CASCADE,
  problem_number TEXT DEFAULT '',
  image_url TEXT NOT NULL,
  subject TEXT DEFAULT '',
  difficulty INTEGER DEFAULT 0 CHECK (difficulty >= 0 AND difficulty <= 5),
  tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  notes TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스 생성
CREATE INDEX IF NOT EXISTS idx_problem_bank_academy ON problem_bank(academy_id);
CREATE INDEX IF NOT EXISTS idx_problem_bank_subject ON problem_bank(subject);
CREATE INDEX IF NOT EXISTS idx_problem_bank_difficulty ON problem_bank(difficulty);
CREATE INDEX IF NOT EXISTS idx_problem_bank_tags ON problem_bank USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_problem_bank_created ON problem_bank(created_at DESC);

-- RLS 정책
ALTER TABLE problem_bank ENABLE ROW LEVEL SECURITY;

-- 읽기: 같은 academy_id
CREATE POLICY "problem_bank_select" ON problem_bank
  FOR SELECT USING (
    academy_id IN (
      SELECT academy_id FROM memberships 
      WHERE user_id = auth.uid()
    )
  );

-- 삽입: 같은 academy_id
CREATE POLICY "problem_bank_insert" ON problem_bank
  FOR INSERT WITH CHECK (
    academy_id IN (
      SELECT academy_id FROM memberships 
      WHERE user_id = auth.uid()
    )
  );

-- 수정: 같은 academy_id
CREATE POLICY "problem_bank_update" ON problem_bank
  FOR UPDATE USING (
    academy_id IN (
      SELECT academy_id FROM memberships 
      WHERE user_id = auth.uid()
    )
  );

-- 삭제: 같은 academy_id
CREATE POLICY "problem_bank_delete" ON problem_bank
  FOR DELETE USING (
    academy_id IN (
      SELECT academy_id FROM memberships 
      WHERE user_id = auth.uid()
    )
  );

-- updated_at 자동 갱신 트리거
CREATE TRIGGER problem_bank_updated_at
  BEFORE UPDATE ON problem_bank
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- Storage 정책 (problem-images 버킷)
CREATE POLICY "problem_images_select" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'problem-images'
  );

CREATE POLICY "problem_images_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'problem-images'
    AND EXISTS (
      SELECT 1 FROM memberships
      WHERE user_id = auth.uid()
        AND academy_id = split_part(name, '/', 1)::uuid
    )
  );

CREATE POLICY "problem_images_update" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'problem-images'
    AND EXISTS (
      SELECT 1 FROM memberships
      WHERE user_id = auth.uid()
        AND academy_id = split_part(name, '/', 1)::uuid
    )
  );

CREATE POLICY "problem_images_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'problem-images'
    AND EXISTS (
      SELECT 1 FROM memberships
      WHERE user_id = auth.uid()
        AND academy_id = split_part(name, '/', 1)::uuid
    )
  );

