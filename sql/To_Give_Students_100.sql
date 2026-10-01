DO $$
DECLARE
  v_year_id uuid := 'e079db08-45f6-4e68-8219-238349851983';
  v_dates date[] := ARRAY[
    '2026-09-27'::date,
    '2026-09-28'::date,
    '2026-09-29'::date,
    '2026-10-01'::date
  ];
  v_tz text := 'Asia/Damascus';
  v_fallback_scanner uuid;
BEGIN
  -- تفعيل bypass الخاص بنافذة الحضور (محلي ضمن هذا الـ transaction فقط)
  PERFORM set_config('app.allow_late_attendance', 'on', true);

  SELECT p.id
  INTO v_fallback_scanner
  FROM public.profiles p
  WHERE p.role = 'resident'
  ORDER BY p.created_at
  LIMIT 1;

  CREATE TEMP TABLE tmp_target_rows ON COMMIT DROP AS
  SELECT
    la.student_id,
    l.id AS lecture_id,
    COALESCE(l.resident_id, v_fallback_scanner) AS scanner_id,
    (l.start_at AT TIME ZONE v_tz)::date AS lecture_local_date,
    COALESCE(s.needed_hours, 0)::int AS needed_minutes
  FROM public.lecture_assignments la
  JOIN public.lectures l ON l.id = la.lecture_id
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  JOIN public.subjects s ON s.id = ps.subject_id
  JOIN public.profiles st ON st.id = la.student_id AND st.role = 'student'
  JOIN public.categories c ON c.id = st.category_id
  WHERE c.year_id = v_year_id
    AND (l.start_at AT TIME ZONE v_tz)::date = ANY (v_dates)
    AND (l.start_at AT TIME ZONE v_tz)::time = time '00:00:00';

  -- تحديث الموجود (يبقي scanned_at/check_in_at كما هي)
  UPDATE public.practical_attendance pa
  SET
    check_out_at = pa.check_in_at + (tr.needed_minutes * INTERVAL '1 minute'),
    duration_minutes = tr.needed_minutes
  FROM tmp_target_rows tr
  WHERE pa.student_id = tr.student_id
    AND pa.lecture_id = tr.lecture_id
    AND pa.check_in_at IS NOT NULL;

  -- إدراج غير الموجود (12:00 PM بالتاريخ المحلي السوري نفسه)
  INSERT INTO public.practical_attendance (
    student_id,
    lecture_id,
    scanned_by,
    scanned_at,
    check_in_at,
    check_out_at,
    duration_minutes
  )
  SELECT
    tr.student_id,
    tr.lecture_id,
    tr.scanner_id,
    ((tr.lecture_local_date::timestamp + time '12:00:00') AT TIME ZONE v_tz),
    ((tr.lecture_local_date::timestamp + time '12:00:00') AT TIME ZONE v_tz),
    (((tr.lecture_local_date::timestamp + time '12:00:00') AT TIME ZONE v_tz)
      + (tr.needed_minutes * INTERVAL '1 minute')),
    tr.needed_minutes
  FROM tmp_target_rows tr
  WHERE tr.scanner_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.practical_attendance pa
      WHERE pa.student_id = tr.student_id
        AND pa.lecture_id = tr.lecture_id
    );

  RAISE NOTICE 'Compensation completed successfully.';
END$$;