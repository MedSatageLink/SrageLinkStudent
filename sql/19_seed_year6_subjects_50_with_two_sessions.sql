-- ============================================================
-- Seed 50 subjects for year 6 + 2 practical sessions each
-- year_id: e079db08-45f6-4e68-8219-238349851983
-- ============================================================

-- Ensure required column exists on older databases
ALTER TABLE public.practical_sessions
  ADD COLUMN IF NOT EXISTS order_index INT NOT NULL DEFAULT 0;

-- 1) Upsert subjects by rotation order
WITH seed_subjects AS (
  SELECT
    gs AS rotation_order,
    'المادة ' || gs::text AS name
  FROM generate_series(1, 40) AS gs
)
UPDATE public.subjects sb
SET name = s.name
FROM seed_subjects s
WHERE sb.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
  AND sb.rotation_order = s.rotation_order;

WITH seed_subjects AS (
  SELECT
    gs AS rotation_order,
    'المادة ' || gs::text AS name
  FROM generate_series(1, 40) AS gs
)
INSERT INTO public.subjects (name, year_id, rotation_order)
SELECT
  s.name,
  'e079db08-45f6-4e68-8219-238349851983'::uuid,
  s.rotation_order
FROM seed_subjects s
WHERE NOT EXISTS (
  SELECT 1
  FROM public.subjects sb
  WHERE sb.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
    AND sb.rotation_order = s.rotation_order
);

-- 2) Ensure session #1 exists (order_index=1)
UPDATE public.practical_sessions ps
SET title = 'الجلسة الأولى'
FROM public.subjects sb
WHERE sb.id = ps.subject_id
  AND sb.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
  AND sb.rotation_order BETWEEN 1 AND 40
  AND ps.order_index = 1;

INSERT INTO public.practical_sessions (subject_id, title, order_index)
SELECT
  sb.id,
  'الجلسة الأولى',
  1
FROM public.subjects sb
WHERE sb.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
  AND sb.rotation_order BETWEEN 1 AND 40
  AND NOT EXISTS (
    SELECT 1
    FROM public.practical_sessions ps
    WHERE ps.subject_id = sb.id
      AND ps.order_index = 1
  );

-- 3) Ensure session #2 exists (order_index=2)
UPDATE public.practical_sessions ps
SET title = 'الجلسة الثانية'
FROM public.subjects sb
WHERE sb.id = ps.subject_id
  AND sb.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
  AND sb.rotation_order BETWEEN 1 AND 40
  AND ps.order_index = 2;

INSERT INTO public.practical_sessions (subject_id, title, order_index)
SELECT
  sb.id,
  'الجلسة الثانية',
  2
FROM public.subjects sb
WHERE sb.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
  AND sb.rotation_order BETWEEN 1 AND 40
  AND NOT EXISTS (
    SELECT 1
    FROM public.practical_sessions ps
    WHERE ps.subject_id = sb.id
      AND ps.order_index = 2
  );

-- 4) Return subject + sessions mapping as JSON (copy-friendly)
SELECT jsonb_pretty(
  jsonb_agg(
    jsonb_build_object(
      'subject_rotation_order', s.rotation_order,
      'subject_id', sb.id,
      'subject_name', COALESCE(sb.name, 'المادة ' || s.rotation_order::text),
      'sessions', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'session_id', ps.id,
            'order_index', ps.order_index,
            'title', ps.title
          )
          ORDER BY ps.order_index, ps.created_at
        )
        FROM public.practical_sessions ps
        WHERE ps.subject_id = sb.id
      )
    )
    ORDER BY s.rotation_order
  )
) AS subjects_sessions_map
FROM generate_series(1, 40) AS s(rotation_order)
LEFT JOIN public.subjects sb
  ON sb.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
 AND sb.rotation_order = s.rotation_order;
