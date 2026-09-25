-- ============================================================
-- StageLink — Step 29: Rebalance subgroup letters by order_number
-- ============================================================
-- Goal:
--   - Rewrite existing subgroup letters in lecture_assignments so they become
--     contiguous by student order within each lecture (instead of alternating).
--   - Example for A/B:
--       6 students -> A A A B B B
--       7 students -> A A A A B B B
--
-- Notes:
--   - This migration targets smart-rotation lectures only.
--   - Ordering inside each lecture uses:
--       profiles.order_number ASC NULLS LAST, profiles.full_name ASC, student_id ASC
--   - Works for any subgroup count already present per lecture (A/B/C...).

CREATE OR REPLACE FUNCTION public._subgroup_index_to_letters(p_index INT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  n INT := p_index;
  rem INT;
  out_text TEXT := '';
BEGIN
  IF p_index IS NULL OR p_index < 0 THEN
    RETURN NULL;
  END IF;

  LOOP
    rem := n % 26;
    out_text := chr(65 + rem) || out_text;
    n := (n / 26) - 1;
    EXIT WHEN n < 0;
  END LOOP;

  RETURN out_text;
END;
$$;

WITH subgroup_counts AS (
  SELECT
    la.lecture_id,
    COUNT(DISTINCT la.subgroup_letter)::INT AS subgroup_count
  FROM public.lecture_assignments la
  JOIN public.lectures l
    ON l.id = la.lecture_id
  WHERE la.subgroup_letter IS NOT NULL
    AND COALESCE(l.generation_mode, '') = 'smart_rotation'
  GROUP BY la.lecture_id
),
base AS (
  SELECT
    la.id,
    la.lecture_id,
    la.student_id,
    la.subgroup_letter,
    p.order_number,
    p.full_name,
    ROW_NUMBER() OVER (
      PARTITION BY la.lecture_id
      ORDER BY p.order_number NULLS LAST, p.full_name, la.student_id
    ) AS rn,
    COUNT(*) OVER (PARTITION BY la.lecture_id) AS total_students,
    sc.subgroup_count
  FROM public.lecture_assignments la
  JOIN public.lectures l
    ON l.id = la.lecture_id
  JOIN public.profiles p
    ON p.id = la.student_id
  JOIN subgroup_counts sc
    ON sc.lecture_id = la.lecture_id
  WHERE la.subgroup_letter IS NOT NULL
    AND COALESCE(l.generation_mode, '') = 'smart_rotation'
),
calc AS (
  SELECT
    b.*,
    (b.total_students / NULLIF(b.subgroup_count, 0))::INT AS base_size,
    (b.total_students % NULLIF(b.subgroup_count, 0))::INT AS remainder,
    (b.subgroup_count - (b.total_students % NULLIF(b.subgroup_count, 0))::INT) AS small_groups,
    (
      CASE
        WHEN b.subgroup_count <= 1 THEN 0
        WHEN (b.total_students / NULLIF(b.subgroup_count, 0))::INT = 0
          THEN LEAST(b.rn - 1, b.subgroup_count - 1)
        WHEN b.rn <= (b.subgroup_count - (b.total_students % b.subgroup_count)) * ((b.total_students / b.subgroup_count)::INT)
          THEN ((b.rn - 1) / ((b.total_students / b.subgroup_count)::INT))
        ELSE
          (b.subgroup_count - (b.total_students % b.subgroup_count))
          + ((b.rn - 1 - ((b.subgroup_count - (b.total_students % b.subgroup_count)) * ((b.total_students / b.subgroup_count)::INT)))
             / (((b.total_students / b.subgroup_count)::INT) + 1))
      END
    )::INT AS subgroup_index
  FROM base b
),
updates AS (
  SELECT
    c.id,
    public._subgroup_index_to_letters(c.subgroup_index) AS new_subgroup_letter
  FROM calc c
)
UPDATE public.lecture_assignments la
SET subgroup_letter = u.new_subgroup_letter
FROM updates u
WHERE la.id = u.id
  AND la.subgroup_letter IS DISTINCT FROM u.new_subgroup_letter;

-- One-off helper cleanup (keep schema clean after this migration runs once)
DROP FUNCTION IF EXISTS public._subgroup_index_to_letters(INT);

-- Optional verification query:
-- SELECT
--   la.lecture_id,
--   la.subgroup_letter,
--   COUNT(*) AS cnt,
--   MIN(p.order_number) AS min_order,
--   MAX(p.order_number) AS max_order
-- FROM public.lecture_assignments la
-- JOIN public.profiles p ON p.id = la.student_id
-- JOIN public.lectures l ON l.id = la.lecture_id
-- WHERE COALESCE(l.generation_mode, '') = 'smart_rotation'
--   AND la.subgroup_letter IS NOT NULL
-- GROUP BY la.lecture_id, la.subgroup_letter
-- ORDER BY la.lecture_id, la.subgroup_letter;
