-- ============================================================
-- StageLink — Step 17: Smart Rotation Scheduler schema support
-- ============================================================

-- 1) Rotation order for subjects (within academic year)
ALTER TABLE public.subjects
  ADD COLUMN IF NOT EXISTS rotation_order INT;

-- 2) Rotation order for categories (within academic year)
ALTER TABLE public.categories
  ADD COLUMN IF NOT EXISTS rotation_order INT;

-- 3) Subgroup letter for assignment rows (A, B, C ...)
ALTER TABLE public.lecture_assignments
  ADD COLUMN IF NOT EXISTS subgroup_letter TEXT;

-- 4) Optional metadata for generated lectures
ALTER TABLE public.lectures
  ADD COLUMN IF NOT EXISTS target_category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS generation_batch_id UUID,
  ADD COLUMN IF NOT EXISTS generation_mode TEXT;

-- 5) Per-year uniqueness for rotation order when value exists
CREATE UNIQUE INDEX IF NOT EXISTS uq_subjects_rotation_order_per_year
  ON public.subjects(year_id, rotation_order)
  WHERE rotation_order IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_categories_rotation_order_per_year
  ON public.categories(year_id, rotation_order)
  WHERE rotation_order IS NOT NULL;

-- 6) Soft validation for subgroup letter format
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_lecture_assignments_subgroup_letter'
  ) THEN
    ALTER TABLE public.lecture_assignments
      ADD CONSTRAINT chk_lecture_assignments_subgroup_letter
      CHECK (
        subgroup_letter IS NULL
        OR subgroup_letter ~ '^[A-Z]{1,4}$'
      );
  END IF;
END$$;

-- 7) Helpful indexes for batch generated schedules
CREATE INDEX IF NOT EXISTS idx_lectures_generation_batch_id
  ON public.lectures(generation_batch_id);

CREATE INDEX IF NOT EXISTS idx_lectures_target_category_id
  ON public.lectures(target_category_id);
