-- =========================================================
-- Department students progress as JSON
-- =========================================================

CREATE OR REPLACE FUNCTION public.get_department_students_progress_json(
  p_department_ids UUID[]
)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
WITH selected_depts AS (
  SELECT d.id, d.name, d.year_id
  FROM public.training_departments d
  WHERE d.id = ANY (p_department_ids)
),
dept_count AS (
  SELECT COUNT(*)::INT AS c FROM selected_depts
),
dept_subjects AS (
  SELECT
    d.id AS department_id,
    d.name AS department_name,
    d.year_id,
    ds.subject_id,
    COALESCE(s.needed_hours, 0)::NUMERIC AS needed_minutes_per_session
  FROM selected_depts d
  JOIN public.training_department_subjects ds
    ON ds.department_id = d.id
  JOIN public.subjects s
    ON s.id = ds.subject_id
),
dept_lectures AS (
  SELECT
    ds.department_id,
    ds.department_name,
    ds.year_id,
    l.id AS lecture_id,
    ds.needed_minutes_per_session
  FROM dept_subjects ds
  JOIN public.practical_sessions ps
    ON ps.subject_id = ds.subject_id
  JOIN public.lectures l
    ON l.practical_session_id = ps.id
),
students_in_scope AS (
  SELECT DISTINCT
    p.id AS student_id,
    p.full_name,
    p.university_id,
    p.order_number,
    c.year_id
  FROM public.profiles p
  JOIN public.categories c
    ON c.id = p.category_id
  JOIN selected_depts d
    ON d.year_id = c.year_id
  WHERE p.role = 'student'
),
required_per_student_dept AS (
  SELECT
    s.student_id,
    d.id AS department_id,
    COALESCE(SUM(dl.needed_minutes_per_session), 0)::NUMERIC AS required_minutes
  FROM students_in_scope s
  JOIN selected_depts d
    ON d.year_id = s.year_id
  LEFT JOIN public.lecture_assignments la
    ON la.student_id = s.student_id
  LEFT JOIN dept_lectures dl
    ON dl.department_id = d.id
   AND dl.lecture_id = la.lecture_id
  GROUP BY s.student_id, d.id
),
spent_per_student_dept AS (
  SELECT
    s.student_id,
    d.id AS department_id,
    COALESCE(
      SUM(
        CASE
          WHEN pa.id IS NULL THEN 0
          WHEN pa.duration_minutes IS NOT NULL THEN GREATEST(0, pa.duration_minutes)::NUMERIC
          WHEN pa.check_in_at IS NOT NULL AND pa.check_out_at IS NOT NULL THEN
            GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (pa.check_out_at - pa.check_in_at)) / 60.0)::INT)::NUMERIC
          WHEN pa.check_in_at IS NOT NULL AND pa.check_out_at IS NULL THEN
            GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - pa.check_in_at)) / 60.0)::INT)::NUMERIC
          ELSE 0
        END
      ),
      0
    )::NUMERIC AS spent_minutes
  FROM students_in_scope s
  JOIN selected_depts d
    ON d.year_id = s.year_id
  LEFT JOIN public.lecture_assignments la
    ON la.student_id = s.student_id
  LEFT JOIN dept_lectures dl
    ON dl.department_id = d.id
   AND dl.lecture_id = la.lecture_id
  LEFT JOIN public.practical_attendance pa
    ON pa.student_id = s.student_id
   AND pa.lecture_id = dl.lecture_id
  GROUP BY s.student_id, d.id
),
metrics AS (
  SELECT
    s.student_id,
    s.full_name,
    s.university_id,
    s.order_number,
    d.id AS department_id,
    d.name AS department_name,
    d.year_id,
    COALESCE(r.required_minutes, 0) AS required_minutes,
    COALESCE(sp.spent_minutes, 0) AS spent_minutes,
    CASE
      WHEN COALESCE(r.required_minutes, 0) <= 0 THEN 0
      ELSE ROUND((COALESCE(sp.spent_minutes, 0) / r.required_minutes) * 100, 2)
    END AS progress_percent
  FROM students_in_scope s
  JOIN selected_depts d
    ON d.year_id = s.year_id
  LEFT JOIN required_per_student_dept r
    ON r.student_id = s.student_id
   AND r.department_id = d.id
  LEFT JOIN spent_per_student_dept sp
    ON sp.student_id = s.student_id
   AND sp.department_id = d.id
),
single_dept AS (
  SELECT id, name, year_id
  FROM selected_depts
  ORDER BY name
  LIMIT 1
),
single_rows AS (
  SELECT
    m.full_name,
    m.university_id,
    m.order_number,
    m.spent_minutes,
    m.required_minutes,
    m.progress_percent
  FROM metrics m
  JOIN single_dept sd
    ON sd.id = m.department_id
),
multi_extra_rows AS (
  SELECT
    m.student_id,
    format('عدد الساعات المطلوبة للقسم %s', m.department_name) AS k,
    to_jsonb(
      format(
        '%s ساعة و %s دقيقة',
        FLOOR(m.required_minutes / 60)::INT,
        ROUND(m.required_minutes - (FLOOR(m.required_minutes / 60) * 60))::INT
      )
    ) AS v
  FROM metrics m

  UNION ALL

  SELECT
    m.student_id,
    format('عدد الساعات المحققة في قسم %s', m.department_name) AS k,
    to_jsonb(
      format(
        '%s ساعة و %s دقيقة',
        FLOOR(m.spent_minutes / 60)::INT,
        ROUND(m.spent_minutes - (FLOOR(m.spent_minutes / 60) * 60))::INT
      )
    ) AS v
  FROM metrics m

  UNION ALL

  SELECT
    m.student_id,
    format('نسبة الإنجاز في قسم %s', m.department_name) AS k,
    to_jsonb(m.progress_percent)
  FROM metrics m
),
multi_extra_by_student AS (
  SELECT
    student_id,
    jsonb_object_agg(k, v ORDER BY k) AS obj
  FROM multi_extra_rows
  GROUP BY student_id
),
multi_students AS (
  SELECT
    s.student_id,
    jsonb_build_object(
      'full_name', s.full_name,
      'university_id', s.university_id,
      'order_number', s.order_number
    ) || COALESCE(me.obj, '{}'::jsonb) AS student_json,
    s.order_number,
    s.full_name
  FROM students_in_scope s
  LEFT JOIN multi_extra_by_student me
    ON me.student_id = s.student_id
)
SELECT CASE
  WHEN (SELECT c FROM dept_count) = 0 THEN '{}'::jsonb

  WHEN (SELECT c FROM dept_count) = 1 THEN
    jsonb_build_object(
      'department_id', (SELECT id FROM single_dept),
      'department_name', (SELECT name FROM single_dept),
      'year_id', (SELECT year_id FROM single_dept),
      'students',
        COALESCE(
          (
            SELECT jsonb_agg(
              jsonb_build_object(
                'full_name', r.full_name,
                'university_id', r.university_id,
                'order_number', r.order_number,
                'spent_hours', ROUND((r.spent_minutes / 60.0), 2),
                'required_hours', ROUND((r.required_minutes / 60.0), 2),
                'progress_percent', r.progress_percent
              )
              ORDER BY r.order_number NULLS LAST, r.full_name
            )
            FROM single_rows r
          ),
          '[]'::jsonb
        )
    )

  ELSE
    jsonb_build_object(
      'department_ids', (SELECT jsonb_agg(id ORDER BY id) FROM selected_depts),
      'students',
        COALESCE(
          (
            SELECT jsonb_agg(
              ms.student_json
              ORDER BY ms.order_number NULLS LAST, ms.full_name
            )
            FROM multi_students ms
          ),
          '[]'::jsonb
        )
    )
END;
$$;

-- Overload for backward compatibility with single department id.
CREATE OR REPLACE FUNCTION public.get_department_students_progress_json(
  p_department_id UUID
)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.get_department_students_progress_json(ARRAY[p_department_id]::UUID[]);
$$;

-- Example call:
-- ضع هنا training_departments.id للقسم المطلوب
SELECT public.get_department_students_progress_json('2381536a-95b6-4baf-951b-2777c49ed1ea'::uuid);

-- Example (multiple departments):
 SELECT public.get_department_students_progress_json(
   ARRAY[
     '2381536a-95b6-4baf-951b-2777c49ed1ea'::uuid,
     '3da35c6e-931c-44f4-aec4-216b7d33f90a'::uuid,
     '5eadc257-a70c-4ca5-8298-07d9db9e8a94'::uuid,
     '9e31289c-2262-462b-97cb-14af67592234'::uuid,
     'a85ea577-42b5-411c-a292-8de79c1e4186'::uuid,
     'b0d18789-ece8-4186-8870-7150d3e01acb'::uuid,
     'b2d0734a-dd84-447c-bc11-4170cb6f6fd5'::uuid,
     'fc1bd20c-9b8b-4573-be76-3d27adb289ad'::uuid
   ]
 );