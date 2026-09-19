-- ============================================================
-- StageLink — Step 23: Multi-subject assignment for residents
-- ============================================================

-- 1) Junction table (idempotent)
CREATE TABLE IF NOT EXISTS public.user_subject_assignments (
  id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  subject_id UUID        NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, subject_id)
);

CREATE INDEX IF NOT EXISTS idx_user_subject_assignments_user
  ON public.user_subject_assignments(user_id);

CREATE INDEX IF NOT EXISTS idx_user_subject_assignments_subject
  ON public.user_subject_assignments(subject_id);

-- 2) RLS for assignment table
ALTER TABLE public.user_subject_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_subject_assignments_select" ON public.user_subject_assignments;
CREATE POLICY "user_subject_assignments_select" ON public.user_subject_assignments
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR public.get_my_role() = 'admin'
  );

DROP POLICY IF EXISTS "user_subject_assignments_admin_insert" ON public.user_subject_assignments;
CREATE POLICY "user_subject_assignments_admin_insert" ON public.user_subject_assignments
  FOR INSERT TO authenticated
  WITH CHECK (public.get_my_role() = 'admin');

DROP POLICY IF EXISTS "user_subject_assignments_admin_update" ON public.user_subject_assignments;
CREATE POLICY "user_subject_assignments_admin_update" ON public.user_subject_assignments
  FOR UPDATE TO authenticated
  USING (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

DROP POLICY IF EXISTS "user_subject_assignments_admin_delete" ON public.user_subject_assignments;
CREATE POLICY "user_subject_assignments_admin_delete" ON public.user_subject_assignments
  FOR DELETE TO authenticated
  USING (public.get_my_role() = 'admin');

-- 3) Helpers based on new junction table
CREATE OR REPLACE FUNCTION public.get_my_subject_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT usa.subject_id
  FROM public.user_subject_assignments usa
  WHERE usa.user_id = auth.uid()
  ORDER BY usa.created_at ASC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.has_subject_assignment(
  p_user_id UUID,
  p_subject_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_subject_assignments usa
    WHERE usa.user_id = p_user_id
      AND usa.subject_id = p_subject_id
  );
$$;

-- 4) Update lecture select policy for resident multi-subject scope
DROP POLICY IF EXISTS "lectures_select" ON public.lectures;
CREATE POLICY "lectures_select" ON public.lectures
  FOR SELECT TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND EXISTS (
        SELECT 1
        FROM public.practical_sessions ps
        WHERE ps.id = lectures.practical_session_id
          AND ps.subject_id = public.get_my_subject_id()
      )
    )
    OR (
      public.get_my_role() = 'student'
      AND EXISTS (
        SELECT 1
        FROM public.lecture_assignments la
        WHERE la.lecture_id = lectures.id
          AND la.student_id = auth.uid()
      )
    )
    OR (
      public.get_my_role() = 'resident'
      AND EXISTS (
        SELECT 1
        FROM public.practical_sessions ps
        WHERE ps.id = lectures.practical_session_id
          AND public.has_subject_assignment(auth.uid(), ps.subject_id)
          AND (lectures.resident_id IS NULL OR lectures.resident_id = auth.uid())
      )
    )
  );

-- Rebuild lecture_assignments policies as non-recursive (no reference to lectures table)
DROP POLICY IF EXISTS "assignments_select" ON public.lecture_assignments;
DROP POLICY IF EXISTS "assignments_admin_all" ON public.lecture_assignments;
DROP POLICY IF EXISTS "assignments_student_select_own" ON public.lecture_assignments;
DROP POLICY IF EXISTS "assignments_resident_select_subject" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Admins manage lecture_assignments" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Students view own lecture assignments" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Residents view assignments for their lectures" ON public.lecture_assignments;

CREATE POLICY "assignments_admin_all" ON public.lecture_assignments
  FOR ALL TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND EXISTS (
        SELECT 1
        FROM public.practical_sessions ps
        WHERE ps.id = lecture_assignments.practical_session_id
          AND public.has_subject_assignment(auth.uid(), ps.subject_id)
      )
    )
  )
  WITH CHECK (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND EXISTS (
        SELECT 1
        FROM public.practical_sessions ps
        WHERE ps.id = lecture_assignments.practical_session_id
          AND public.has_subject_assignment(auth.uid(), ps.subject_id)
      )
    )
  );

CREATE POLICY "assignments_student_select_own" ON public.lecture_assignments
  FOR SELECT TO authenticated
  USING (
    public.get_my_role() = 'student'
    AND student_id = auth.uid()
  );

CREATE POLICY "assignments_resident_select_subject" ON public.lecture_assignments
  FOR SELECT TO authenticated
  USING (
    public.get_my_role() = 'resident'
    AND EXISTS (
      SELECT 1
      FROM public.practical_sessions ps
      WHERE ps.id = lecture_assignments.practical_session_id
        AND public.has_subject_assignment(auth.uid(), ps.subject_id)
    )
  );

DROP POLICY IF EXISTS "lecture_handover_history_select" ON public.lecture_resident_handover_history;
CREATE POLICY "lecture_handover_history_select" ON public.lecture_resident_handover_history
  FOR SELECT TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role() = 'resident'
      AND EXISTS (
        SELECT 1
        FROM public.lectures l
        JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
        WHERE l.id = lecture_resident_handover_history.lecture_id
          AND public.has_subject_assignment(auth.uid(), ps.subject_id)
      )
    )
  );

-- 5) Attendance scan function: resident authorization now via assignment table
CREATE OR REPLACE FUNCTION public.record_practical_scan_event(
  p_lecture_id UUID,
  p_student_id UUID,
  p_event_type TEXT,
  p_idempotency_key TEXT,
  p_scanned_local_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                  UUID := auth.uid();
  v_role                 user_role;
  v_window_start         TIMESTAMPTZ;
  v_window_end           TIMESTAMPTZ;
  v_student_name         TEXT;
  v_resident_name        TEXT;
  v_session_title        TEXT;
  v_start_at             TIMESTAMPTZ;
  v_location             TEXT;
  v_prereq_video         UUID;
  v_completed            BOOLEAN;
  v_att                  public.practical_attendance%ROWTYPE;
  v_att_id               UUID;
  v_queue_id             UUID;
  v_scan_at              TIMESTAMPTZ := COALESCE(p_scanned_local_at, NOW());
  v_lecture_resident_id  UUID;
  v_lecture_subject_id   UUID;
  v_open_handover_id     UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
  END IF;

  IF p_event_type NOT IN ('check_in', 'check_out') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_event_type');
  END IF;

  SELECT role
    INTO v_role
  FROM public.profiles
  WHERE id = v_uid;

  IF v_role <> 'resident' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Resident only');
  END IF;

  SELECT l.resident_id, ps.subject_id
    INTO v_lecture_resident_id, v_lecture_subject_id
  FROM public.lectures l
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  WHERE l.id = p_lecture_id
  FOR UPDATE OF l;

  IF v_lecture_subject_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'lecture_not_found');
  END IF;

  IF NOT public.has_subject_assignment(v_uid, v_lecture_subject_id) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'resident_not_allowed_for_subject');
  END IF;

  IF v_lecture_resident_id IS NULL THEN
    UPDATE public.lectures
    SET resident_id = v_uid
    WHERE id = p_lecture_id;

    SELECT id
      INTO v_open_handover_id
    FROM public.lecture_resident_handover_history
    WHERE lecture_id = p_lecture_id
      AND to_resident_id IS NULL
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_open_handover_id IS NOT NULL THEN
      UPDATE public.lecture_resident_handover_history
      SET to_resident_id = v_uid,
          claimed_at = NOW()
      WHERE id = v_open_handover_id;
    END IF;

    v_lecture_resident_id := v_uid;
  ELSIF v_lecture_resident_id <> v_uid THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'lecture_claimed_by_other_resident');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lecture_assignments
    WHERE lecture_id = p_lecture_id
      AND student_id = p_student_id
  ) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Student not assigned');
  END IF;

  SELECT ps.prerequisite_video_id INTO v_prereq_video
  FROM public.lectures l
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  WHERE l.id = p_lecture_id;

  IF v_prereq_video IS NOT NULL THEN
    SELECT is_completed INTO v_completed
    FROM public.video_attendance
    WHERE student_id = p_student_id
      AND video_id = v_prereq_video;

    IF COALESCE(v_completed, FALSE) = FALSE THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'prerequisite_required');
    END IF;
  END IF;

  SELECT l.attendance_window_start,
         l.attendance_window_end,
         l.start_at,
         s.location,
         ps.title,
         sp.full_name,
         rp.full_name
    INTO v_window_start,
         v_window_end,
         v_start_at,
         v_location,
         v_session_title,
         v_student_name,
         v_resident_name
  FROM public.lectures l
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  JOIN public.subjects s ON s.id = ps.subject_id
  LEFT JOIN public.profiles sp ON sp.id = p_student_id
  LEFT JOIN public.profiles rp ON rp.id = v_uid
  WHERE l.id = p_lecture_id;

  SELECT * INTO v_att
  FROM public.practical_attendance
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
  LIMIT 1
  FOR UPDATE;

  IF v_scan_at >= v_window_start AND v_scan_at <= v_window_end THEN
    IF p_event_type = 'check_in' THEN
      IF v_att.id IS NOT NULL AND v_att.check_in_at IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'already_checked_in', 'attendance_id', v_att.id);
      END IF;

      IF v_att.id IS NULL THEN
        INSERT INTO public.practical_attendance (
          student_id,
          lecture_id,
          scanned_by,
          check_in_at,
          check_out_at,
          duration_minutes
        ) VALUES (
          p_student_id,
          p_lecture_id,
          v_uid,
          v_scan_at,
          NULL,
          NULL
        )
        RETURNING id INTO v_att_id;
      ELSE
        UPDATE public.practical_attendance
        SET scanned_by = v_uid,
            check_in_at = v_scan_at
        WHERE id = v_att.id
        RETURNING id INTO v_att_id;
      END IF;

      RETURN jsonb_build_object('status', 'accepted_check_in', 'attendance_id', v_att_id);
    END IF;

    IF v_att.id IS NULL OR v_att.check_in_at IS NULL THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'missing_check_in');
    END IF;

    IF v_att.check_out_at IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'already_checked_out', 'attendance_id', v_att.id);
    END IF;

    UPDATE public.practical_attendance
    SET scanned_by = v_uid,
        check_out_at = v_scan_at,
        duration_minutes = GREATEST(
          0,
          FLOOR(EXTRACT(EPOCH FROM (v_scan_at - v_att.check_in_at)) / 60.0)::INT
        )
    WHERE id = v_att.id
    RETURNING id INTO v_att_id;

    RETURN jsonb_build_object('status', 'accepted_check_out', 'attendance_id', v_att_id);
  END IF;

  SELECT id INTO v_queue_id
  FROM public.practical_attendance_queue
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
    AND event_type = p_event_type
    AND status = 'pending_admin'
  LIMIT 1;

  IF v_queue_id IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'queued_for_approval', 'queue_id', v_queue_id);
  END IF;

  INSERT INTO public.practical_attendance_queue (
    idempotency_key,
    lecture_id,
    student_id,
    resident_id,
    event_type,
    scanned_local_at,
    status,
    student_name,
    resident_name,
    session_title,
    lecture_start_at,
    location
  ) VALUES (
    p_idempotency_key,
    p_lecture_id,
    p_student_id,
    v_uid,
    p_event_type,
    v_scan_at,
    'pending_admin',
    COALESCE(v_student_name, ''),
    COALESCE(v_resident_name, ''),
    COALESCE(v_session_title, ''),
    v_start_at,
    v_location
  )
  ON CONFLICT (idempotency_key) DO UPDATE
    SET idempotency_key = EXCLUDED.idempotency_key
  RETURNING id INTO v_queue_id;

  RETURN jsonb_build_object('status', 'queued_for_approval', 'queue_id', v_queue_id);
END;
$$;

-- 6) Queue approval/rejection scope for mini_admin now via assignment table
CREATE OR REPLACE FUNCTION public.approve_practical_scan_queue(
  p_queue_id UUID,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role      user_role;
  v_uid       UUID := auth.uid();
  v_item      public.practical_attendance_queue%ROWTYPE;
  v_att       public.practical_attendance%ROWTYPE;
  v_att_id    UUID;
  v_queue_subject UUID;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role::text NOT IN ('admin', 'mini_admin') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Admin only');
  END IF;

  SELECT * INTO v_item
  FROM public.practical_attendance_queue
  WHERE id = p_queue_id
  LIMIT 1;

  IF v_item.id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Queue item not found');
  END IF;

  IF v_role::text = 'mini_admin' THEN
    SELECT ps.subject_id INTO v_queue_subject
    FROM public.lectures l
    JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
    WHERE l.id = v_item.lecture_id;

    IF v_queue_subject IS NULL OR NOT public.has_subject_assignment(v_uid, v_queue_subject) THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'forbidden_subject_scope');
    END IF;
  END IF;

  IF v_item.status <> 'pending_admin' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Queue item already reviewed');
  END IF;

  SELECT * INTO v_att
  FROM public.practical_attendance
  WHERE lecture_id = v_item.lecture_id
    AND student_id = v_item.student_id
  LIMIT 1
  FOR UPDATE;

  IF COALESCE(v_item.event_type, 'check_in') = 'check_in' THEN
    IF v_att.id IS NULL THEN
      PERFORM set_config('app.allow_late_attendance', 'on', true);

      INSERT INTO public.practical_attendance (
        student_id,
        lecture_id,
        scanned_by,
        scanned_at,
        check_in_at,
        approved_late
      )
      VALUES (
        v_item.student_id,
        v_item.lecture_id,
        v_item.resident_id,
        COALESCE(v_item.scanned_local_at, NOW()),
        COALESCE(v_item.scanned_local_at, NOW()),
        TRUE
      )
      RETURNING id INTO v_att_id;
    ELSE
      UPDATE public.practical_attendance
      SET check_in_at = COALESCE(check_in_at, COALESCE(v_item.scanned_local_at, NOW())),
          scanned_by = COALESCE(scanned_by, v_item.resident_id),
          approved_late = TRUE
      WHERE id = v_att.id
      RETURNING id INTO v_att_id;
    END IF;
  ELSE
    IF v_att.id IS NULL OR v_att.check_in_at IS NULL THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'missing_check_in');
    END IF;

    IF v_att.check_out_at IS NOT NULL THEN
      v_att_id := v_att.id;
    ELSE
      UPDATE public.practical_attendance
      SET check_out_at = COALESCE(v_item.scanned_local_at, NOW()),
          duration_minutes = GREATEST(
            0,
            FLOOR(EXTRACT(EPOCH FROM (COALESCE(v_item.scanned_local_at, NOW()) - v_att.check_in_at)) / 60.0)::INT
          ),
          approved_late = TRUE
      WHERE id = v_att.id
      RETURNING id INTO v_att_id;
    END IF;
  END IF;

  UPDATE public.practical_attendance_queue
  SET status = 'approved',
      attendance_id = v_att_id,
      review_note = p_note,
      reviewed_by = v_uid,
      reviewed_at = NOW()
  WHERE id = p_queue_id;

  RETURN jsonb_build_object('status', 'approved', 'attendance_id', v_att_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_practical_scan_queue(
  p_queue_id UUID,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role user_role;
  v_uid  UUID := auth.uid();
  v_queue_subject UUID;
  v_lecture_id UUID;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role::text NOT IN ('admin', 'mini_admin') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Admin only');
  END IF;

  IF v_role::text = 'mini_admin' THEN
    SELECT lecture_id INTO v_lecture_id
    FROM public.practical_attendance_queue
    WHERE id = p_queue_id
    LIMIT 1;

    IF v_lecture_id IS NULL THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'Queue item not pending');
    END IF;

    SELECT ps.subject_id INTO v_queue_subject
    FROM public.lectures l
    JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
    WHERE l.id = v_lecture_id;

    IF v_queue_subject IS NULL OR NOT public.has_subject_assignment(v_uid, v_queue_subject) THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'forbidden_subject_scope');
    END IF;
  END IF;

  UPDATE public.practical_attendance_queue
  SET status = 'rejected',
      review_note = p_note,
      reviewed_by = v_uid,
      reviewed_at = NOW()
  WHERE id = p_queue_id
    AND status = 'pending_admin';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Queue item not pending');
  END IF;

  RETURN jsonb_build_object('status', 'rejected');
END;
$$;

-- 7) Remove old single-subject profile linkage completely
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS fk_profiles_subject;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS subject_id;
