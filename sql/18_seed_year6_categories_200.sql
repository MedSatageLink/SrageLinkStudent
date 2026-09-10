-- ============================================================
-- Seed 200 categories for year 6 (2026-2027)
-- year_id: e079db08-45f6-4e68-8219-238349851983
-- ============================================================

WITH seed AS (
  SELECT
    gs AS rotation_order,
    'المجموعة ' || gs::text AS name
  FROM generate_series(1, 200) AS gs
), updated AS (
  UPDATE public.categories c
  SET
    name = s.name,
    academic_year = '2026- 2027'
  FROM seed s
  WHERE c.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
    AND c.rotation_order = s.rotation_order
  RETURNING c.id, c.rotation_order
), inserted AS (
  INSERT INTO public.categories (name, year_id, academic_year, rotation_order)
  SELECT
    s.name,
    'e079db08-45f6-4e68-8219-238349851983'::uuid,
    '2026- 2027',
    s.rotation_order
  FROM seed s
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.categories c
    WHERE c.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
      AND c.rotation_order = s.rotation_order
  )
  RETURNING id, rotation_order
)
SELECT jsonb_pretty(
  jsonb_agg(
    jsonb_build_object(
      'rotation_order', s.rotation_order,
      'id', c.id
    )
    ORDER BY s.rotation_order
  )
) AS categories_rotation_id_map
FROM generate_series(1, 200) AS s(rotation_order)
LEFT JOIN public.categories c
  ON c.year_id = 'e079db08-45f6-4e68-8219-238349851983'::uuid
 AND c.rotation_order = s.rotation_order;
