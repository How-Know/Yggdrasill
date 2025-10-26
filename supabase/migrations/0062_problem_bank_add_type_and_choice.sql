-- 0062: problem_bank에 문제 유형 및 선지 정보 추가

ALTER TABLE problem_bank
  ADD COLUMN IF NOT EXISTS problem_type TEXT DEFAULT '주관식' CHECK (problem_type IN ('주관식', '객관식', '모두')),
  ADD COLUMN IF NOT EXISTS is_essay BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS choice_image_url TEXT DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_problem_bank_type ON problem_bank(problem_type);

