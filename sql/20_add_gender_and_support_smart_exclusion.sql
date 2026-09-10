-- ============================================================
-- Add student gender field and related support
-- ============================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS gender TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_profiles_gender'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT chk_profiles_gender
      CHECK (gender IS NULL OR gender IN ('male', 'female'));
  END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_profiles_role_gender_category
  ON public.profiles(role, gender, category_id);
