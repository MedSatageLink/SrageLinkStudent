-- ============================================================
-- StageLink — Step 25: Subject required duration per session
-- ============================================================

-- Legacy column name is `needed_hours`, but the value is interpreted
-- as required duration in MINUTES per session.
-- Student apps multiply this value by assigned sessions count to
-- compute total required minutes and completion percentage.

ALTER TABLE public.subjects
  ADD COLUMN IF NOT EXISTS needed_hours NUMERIC(6,2);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'subjects_needed_hours_non_negative'
  ) THEN
    ALTER TABLE public.subjects
      ADD CONSTRAINT subjects_needed_hours_non_negative
      CHECK (needed_hours IS NULL OR needed_hours >= 0);
  END IF;
END $$;
