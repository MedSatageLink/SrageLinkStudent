-- ============================================================
-- StageLink — Dynamic resident claim/delegate for practical lectures
-- ============================================================
-- Goal:
-- 1) Admin creates lectures with resident_id = NULL
-- 2) Any resident of the same subject can claim lecture implicitly on first scan
-- 3) Once claimed, only owner resident can continue scanning
-- 4) Owner can release lecture (delegate) to allow another resident to claim
-- 5) RLS for residents shows only eligible lectures/assignments

-- ------------------------------------------------------------
-- 0) Lecture handover metadata (last owner) + full history
-- ------------------------------------------------------------
ALTER TABLE public.lectures
  ADD COLUMN IF NOT EXISTS previous_resident_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS previous_resident_released_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_lectures_previous_resident
  ON public.lectures(previous_resident_id);

CREATE TABLE IF NOT EXISTS public.lecture_resident_handover_history (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  lecture_id       UUID        NOT NULL REFERENCES public.lectures(id) ON DELETE CASCADE,
  event_type       TEXT        NOT NULL CHECK (event_type IN ('claimed', 'released')),
  from_resident_id UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  to_resident_id   UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  actor_resident_id UUID       REFERENCES public.profiles(id) ON DELETE SET NULL,
  occurred_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  note             TEXT
);

CREATE INDEX IF NOT EXISTS idx_lecture_handover_history_lecture
  ON public.lecture_resident_handover_history(lecture_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_lecture_handover_history_actor
  ON public.lecture_resident_handover_history(actor_resident_id, occurred_at DESC);

ALTER TABLE public.lecture_resident_handover_history ENABLE ROW LEVEL SECURITY;

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
        JOIN public.profiles me ON me.id = auth.uid()
        WHERE l.id = lecture_resident_handover_history.lecture_id
          AND me.subject_id IS NOT NULL
          AND me.subject_id = ps.subject_id
      )
    )
  );

-- ------------------------------------------------------------
-- 1) Tighten resident visibility via RLS
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "lectures_select" ON public.lectures;

CREATE POLICY "lectures_select" ON public.lectures
  FOR SELECT TO authenticated
  USING (
    public.get_my_role() = 'admin'
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
        JOIN public.profiles me ON me.id = auth.uid()
        WHERE ps.id = lectures.practical_session_id
          AND me.subject_id IS NOT NULL
          AND me.subject_id = ps.subject_id
          AND (lectures.resident_id IS NULL OR lectures.resident_id = auth.uid())
      )
    )
  );

DROP POLICY IF EXISTS "assignments_select" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Admins manage lecture_assignments" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Students view own lecture assignments" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Residents view assignments for their lectures" ON public.lecture_assignments;

CREATE POLICY "assignments_admin_all" ON public.lecture_assignments
  FOR ALL TO authenticated
  USING (public.get_my_role() = 'admin')
  WITH CHECK (public.get_my_role() = 'admin');

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
      JOIN public.profiles me ON me.id = auth.uid()
      WHERE ps.id = lecture_assignments.practical_session_id
        AND me.subject_id IS NOT NULL
        AND me.subject_id = ps.subject_id
    )
  );

-- ------------------------------------------------------------
-- 2) Attendance submit: implicit claim + subject authorization
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_practical_attendance_event(
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
  v_resident_subject_id  UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
  END IF;

  IF p_event_type NOT IN ('check_in', 'check_out') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_event_type');
  END IF;

  SELECT role, subject_id
    INTO v_role, v_resident_subject_id
  FROM public.profiles
  WHERE id = v_uid;

  IF v_role <> 'resident' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Resident only');
  END IF;

  IF v_resident_subject_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'resident_subject_not_set');
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

  IF v_lecture_subject_id <> v_resident_subject_id THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'resident_not_allowed_for_subject');
  END IF;

  -- First valid scanner claims lecture ownership.
  IF v_lecture_resident_id IS NULL THEN
    UPDATE public.lectures
    SET resident_id = v_uid
    WHERE id = p_lecture_id;

    INSERT INTO public.lecture_resident_handover_history (
      lecture_id,
      event_type,
      from_resident_id,
      to_resident_id,
      actor_resident_id,
      occurred_at,
      note
    ) VALUES (
      p_lecture_id,
      'claimed',
      NULL,
      v_uid,
      v_uid,
      NOW(),
      'Automatic claim on first valid attendance scan'
    );

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
         l.location,
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
  LEFT JOIN public.profiles sp ON sp.id = p_student_id
  LEFT JOIN public.profiles rp ON rp.id = v_uid
  WHERE l.id = p_lecture_id;

  SELECT * INTO v_att
  FROM public.practical_attendance
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
  LIMIT 1
  FOR UPDATE;

  -- IMPORTANT: window validation uses scan time (v_scan_at), not sync time (NOW)
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
          scanned_at,
          check_in_at
        )
        VALUES (
          p_student_id,
          p_lecture_id,
          v_uid,
          v_scan_at,
          v_scan_at
        )
        RETURNING id INTO v_att_id;
      ELSE
        UPDATE public.practical_attendance
        SET scanned_by = v_uid,
            scanned_at = COALESCE(scanned_at, v_scan_at),
            check_in_at = COALESCE(check_in_at, v_scan_at)
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

  -- Out of window at scan time => queue for admin
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

-- ------------------------------------------------------------
-- 3) Delegate API: current owner releases lecture
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_practical_lecture_resident(
  p_lecture_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          UUID := auth.uid();
  v_role         user_role;
  v_current_owner UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
  END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role <> 'resident' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Resident only');
  END IF;

  SELECT resident_id
    INTO v_current_owner
  FROM public.lectures
  WHERE id = p_lecture_id
  FOR UPDATE;

  IF v_current_owner IS NULL THEN
    RETURN jsonb_build_object('status', 'already_unclaimed');
  END IF;

  IF v_current_owner <> v_uid THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'not_lecture_owner');
  END IF;

  INSERT INTO public.lecture_resident_handover_history (
    lecture_id,
    event_type,
    from_resident_id,
    to_resident_id,
    actor_resident_id,
    occurred_at,
    note
  ) VALUES (
    p_lecture_id,
    'released',
    v_current_owner,
    NULL,
    v_uid,
    NOW(),
    'Lecture released by current owner via delegate action'
  );

  UPDATE public.lectures
  SET previous_resident_id = resident_id,
      previous_resident_released_at = NOW(),
      resident_id = NULL
  WHERE id = p_lecture_id;

  RETURN jsonb_build_object('status', 'released');
END;
$$;
