-- ============================================================
-- StageLink — Step 34: Department-based progress tracking
-- ============================================================
-- Adds:
-- 1) training_departments (per year)
-- 2) training_department_subjects (subject mapping)
-- 3) year-consistency trigger for mappings
-- 4) RPC to compute student progress per department in minutes

CREATE TABLE IF NOT EXISTS public.training_departments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  year_id UUID NOT NULL REFERENCES public.years(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  order_index INT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (year_id, name)
);

CREATE TABLE IF NOT EXISTS public.training_department_subjects (
  department_id UUID NOT NULL REFERENCES public.training_departments(id) ON DELETE CASCADE,
  subject_id UUID NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (department_id, subject_id)
);

CREATE INDEX IF NOT EXISTS idx_training_departments_year
  ON public.training_departments(year_id, order_index, name);

CREATE INDEX IF NOT EXISTS idx_training_department_subjects_subject
  ON public.training_department_subjects(subject_id);

CREATE OR REPLACE FUNCTION public.ensure_department_subject_same_year()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dept_year UUID;
  v_subject_year UUID;
BEGIN
  SELECT year_id
    INTO v_dept_year
  FROM public.training_departments
  WHERE id = NEW.department_id;

  SELECT year_id
    INTO v_subject_year
  FROM public.subjects
  WHERE id = NEW.subject_id;

  IF v_dept_year IS NULL OR v_subject_year IS NULL THEN
    RAISE EXCEPTION 'Department or subject not found';
  END IF;

  IF v_dept_year <> v_subject_year THEN
    RAISE EXCEPTION 'Subject year must match department year';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_department_subject_same_year
  ON public.training_department_subjects;

CREATE TRIGGER trg_department_subject_same_year
BEFORE INSERT OR UPDATE ON public.training_department_subjects
FOR EACH ROW
EXECUTE FUNCTION public.ensure_department_subject_same_year();

ALTER TABLE public.training_departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.training_department_subjects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS training_departments_select ON public.training_departments;
DROP POLICY IF EXISTS training_departments_insert ON public.training_departments;
DROP POLICY IF EXISTS training_departments_update ON public.training_departments;
DROP POLICY IF EXISTS training_departments_delete ON public.training_departments;

CREATE POLICY training_departments_select
ON public.training_departments
FOR SELECT TO authenticated
USING (true);

CREATE POLICY training_departments_insert
ON public.training_departments
FOR INSERT TO authenticated
WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY training_departments_update
ON public.training_departments
FOR UPDATE TO authenticated
USING (public.get_my_role() = 'admin')
WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY training_departments_delete
ON public.training_departments
FOR DELETE TO authenticated
USING (public.get_my_role() = 'admin');

DROP POLICY IF EXISTS training_department_subjects_select ON public.training_department_subjects;
DROP POLICY IF EXISTS training_department_subjects_insert ON public.training_department_subjects;
DROP POLICY IF EXISTS training_department_subjects_update ON public.training_department_subjects;
DROP POLICY IF EXISTS training_department_subjects_delete ON public.training_department_subjects;

CREATE POLICY training_department_subjects_select
ON public.training_department_subjects
FOR SELECT TO authenticated
USING (true);

CREATE POLICY training_department_subjects_insert
ON public.training_department_subjects
FOR INSERT TO authenticated
WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY training_department_subjects_update
ON public.training_department_subjects
FOR UPDATE TO authenticated
USING (public.get_my_role() = 'admin')
WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY training_department_subjects_delete
ON public.training_department_subjects
FOR DELETE TO authenticated
USING (public.get_my_role() = 'admin');

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
                   LEAST(
                     a.needed_minutes_per_session,
                     FLOOR(EXTRACT(EPOCH FROM (NOW() - pa.check_in_at)) / 60.0)::INT
                   )
                 )
                 ELSE GREATEST(
                   0,
                   LEAST(
                     a.needed_minutes_per_session,
                     FLOOR(EXTRACT(EPOCH FROM (pa.check_out_at - pa.check_in_at)) / 60.0)::INT
                   )
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
