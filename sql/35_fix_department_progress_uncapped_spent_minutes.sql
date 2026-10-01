-- ============================================================
-- StageLink — Step 35: Do not cap spent minutes per session
-- ============================================================
-- Fixes department progress so spent_minutes sums actual attendance
-- duration even when a single lecture exceeds subject needed_minutes.

CREATE OR REPLACE FUNCTION public.get_student_department_progress(
  p_student_id UUID DEFAULT auth.uid()
)
RETURNS TABLE (
  department_id UUID,
  department_name TEXT,
  year_id UUID,
  spent_minutes INT,
  required_minutes INT,
  progress_percent NUMERIC
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT p_student_id AS student_id
  ),
  my_year AS (
    SELECT c.year_id
    FROM public.profiles p
    JOIN public.categories c ON c.id = p.category_id
    JOIN me ON me.student_id = p.id
    LIMIT 1
  ),
  depts AS (
    SELECT d.id, d.name, d.year_id
    FROM public.training_departments d
    JOIN my_year y ON y.year_id = d.year_id
    WHERE d.is_active = TRUE
  ),
  dept_subjects AS (
    SELECT d.id AS department_id,
           d.name AS department_name,
           d.year_id,
           s.id AS subject_id,
           COALESCE(s.needed_hours, 0)::INT AS needed_minutes_per_session
    FROM depts d
    JOIN public.training_department_subjects ds
      ON ds.department_id = d.id
    JOIN public.subjects s
      ON s.id = ds.subject_id
  ),
  assigned AS (
    SELECT ds.department_id,
           ds.department_name,
           ds.year_id,
           la.lecture_id,
           ds.needed_minutes_per_session
    FROM dept_subjects ds
    JOIN public.practical_sessions ps
      ON ps.subject_id = ds.subject_id
    JOIN public.lectures l
      ON l.practical_session_id = ps.id
    JOIN public.lecture_assignments la
      ON la.lecture_id = l.id
    JOIN me ON me.student_id = la.student_id
  ),
  required AS (
    SELECT a.department_id,
           a.department_name,
           a.year_id,
           COALESCE(SUM(a.needed_minutes_per_session), 0)::INT AS required_minutes
    FROM assigned a
    GROUP BY a.department_id, a.department_name, a.year_id
  ),
  spent AS (
    SELECT a.department_id,
           COALESCE(
             SUM(
               CASE
                 WHEN pa.id IS NULL THEN 0
                 WHEN pa.check_in_at IS NULL THEN 0
                 WHEN pa.check_out_at IS NULL THEN GREATEST(
                   0,
                   FLOOR(EXTRACT(EPOCH FROM (NOW() - pa.check_in_at)) / 60.0)::INT
                 )
                 ELSE GREATEST(
                   0,
                   FLOOR(EXTRACT(EPOCH FROM (pa.check_out_at - pa.check_in_at)) / 60.0)::INT
                 )
               END
             ),
             0
           )::INT AS spent_minutes
    FROM assigned a
    LEFT JOIN public.practical_attendance pa
      ON pa.lecture_id = a.lecture_id
     AND pa.student_id = p_student_id
    GROUP BY a.department_id
  )
  SELECT d.id AS department_id,
         d.name AS department_name,
         d.year_id,
         COALESCE(s.spent_minutes, 0) AS spent_minutes,
         COALESCE(r.required_minutes, 0) AS required_minutes,
         CASE
           WHEN COALESCE(r.required_minutes, 0) <= 0 THEN 0
           ELSE ROUND((COALESCE(s.spent_minutes, 0)::NUMERIC / r.required_minutes::NUMERIC) * 100, 2)
         END AS progress_percent
  FROM depts d
  LEFT JOIN required r ON r.department_id = d.id
  LEFT JOIN spent s ON s.department_id = d.id
  ORDER BY COALESCE((SELECT order_index FROM public.training_departments t WHERE t.id = d.id), 2147483647), d.name;
$$;

GRANT EXECUTE ON FUNCTION public.get_student_department_progress(UUID)
TO authenticated;
