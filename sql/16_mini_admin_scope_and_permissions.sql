-- ============================================================
-- StageLink — Mini Admin role + scoped permissions
-- ============================================================

-- 1) Add new role to enum
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'mini_admin';

-- 2) Helpers
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

-- 3) Profiles visibility: allow mini_admin to see students in same year of assigned subject
DROP POLICY IF EXISTS "profiles_select" ON public.profiles;
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT
  USING (
    id = auth.uid()
    OR public.get_my_role() = 'admin'
    OR (public.get_my_role() = 'resident' AND role = 'student')
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND role = 'student'
      AND EXISTS (
        SELECT 1
        FROM public.subjects s
        JOIN public.categories c ON c.id = profiles.category_id
        WHERE s.id = public.get_my_subject_id()
          AND c.year_id = s.year_id
      )
    )
  );

-- 4) Allow admin reset for mini_admin accounts too
CREATE OR REPLACE FUNCTION public.admin_reset_user_login(
  p_user_id UUID,
  p_mode TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_my_role user_role;
  v_target_role user_role;
  v_target_device TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'unauthorized');
  END IF;

  SELECT role INTO v_my_role FROM public.profiles WHERE id = v_uid;
  IF v_my_role <> 'admin' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'admin_only');
  END IF;

  IF p_mode NOT IN ('same_device', 'any_device') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_mode');
  END IF;

  SELECT role, login_device_id
    INTO v_target_role, v_target_device
  FROM public.profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF v_target_role IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'user_not_found');
  END IF;

  IF v_target_role::text NOT IN ('student', 'resident', 'mini_admin') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'target_not_allowed');
  END IF;

  IF p_mode = 'same_device' AND (v_target_device IS NULL OR LENGTH(TRIM(v_target_device)) = 0) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'same_device_not_possible');
  END IF;

  UPDATE public.profiles
  SET login_activated = TRUE,
      login_reset_mode = p_mode,
      login_enabled = TRUE
  WHERE id = p_user_id;

  RETURN jsonb_build_object('status', 'ok', 'mode', p_mode);
END;
$$;

-- 5) Content policies (mini_admin scoped by assigned subject)
DROP POLICY IF EXISTS "videos_select" ON public.videos;
DROP POLICY IF EXISTS "videos_admin_insert" ON public.videos;
DROP POLICY IF EXISTS "videos_admin_update" ON public.videos;
DROP POLICY IF EXISTS "videos_admin_delete" ON public.videos;

CREATE POLICY "videos_select" ON public.videos
  FOR SELECT TO authenticated
  USING (
    public.get_my_role()::text <> 'mini_admin'
    OR public.get_my_subject_id() = subject_id
  );

CREATE POLICY "videos_admin_insert" ON public.videos
  FOR INSERT TO authenticated
  WITH CHECK (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  );

CREATE POLICY "videos_admin_update" ON public.videos
  FOR UPDATE TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  )
  WITH CHECK (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  );

CREATE POLICY "videos_admin_delete" ON public.videos
  FOR DELETE TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  );

DROP POLICY IF EXISTS "p_sessions_select" ON public.practical_sessions;
DROP POLICY IF EXISTS "p_sessions_admin_insert" ON public.practical_sessions;
DROP POLICY IF EXISTS "p_sessions_admin_update" ON public.practical_sessions;
DROP POLICY IF EXISTS "p_sessions_admin_delete" ON public.practical_sessions;

CREATE POLICY "p_sessions_select" ON public.practical_sessions
  FOR SELECT TO authenticated
  USING (
    public.get_my_role()::text <> 'mini_admin'
    OR public.get_my_subject_id() = subject_id
  );

CREATE POLICY "p_sessions_admin_insert" ON public.practical_sessions
  FOR INSERT TO authenticated
  WITH CHECK (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  );

CREATE POLICY "p_sessions_admin_update" ON public.practical_sessions
  FOR UPDATE TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  )
  WITH CHECK (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  );

CREATE POLICY "p_sessions_admin_delete" ON public.practical_sessions
  FOR DELETE TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND public.get_my_subject_id() = subject_id
    )
  );

DROP POLICY IF EXISTS "lectures_select" ON public.lectures;
DROP POLICY IF EXISTS "lectures_admin_insert" ON public.lectures;
DROP POLICY IF EXISTS "lectures_admin_update" ON public.lectures;
DROP POLICY IF EXISTS "lectures_admin_delete" ON public.lectures;

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
          AND EXISTS (
            SELECT 1
            FROM public.user_subject_assignments usa
            WHERE usa.user_id = auth.uid()
              AND usa.subject_id = ps.subject_id
          )
          AND (lectures.resident_id IS NULL OR lectures.resident_id = auth.uid())
      )
    )
  );

CREATE POLICY "lectures_admin_insert" ON public.lectures
  FOR INSERT TO authenticated
  WITH CHECK (
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
  );

CREATE POLICY "lectures_admin_update" ON public.lectures
  FOR UPDATE TO authenticated
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
  )
  WITH CHECK (
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
  );

CREATE POLICY "lectures_admin_delete" ON public.lectures
  FOR DELETE TO authenticated
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
  );

DROP POLICY IF EXISTS "assignments_admin_all" ON public.lecture_assignments;

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
          AND ps.subject_id = public.get_my_subject_id()
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
          AND ps.subject_id = public.get_my_subject_id()
      )
    )
  );

DROP POLICY IF EXISTS "student_subject_stats_select" ON public.student_subject_stats;
CREATE POLICY "student_subject_stats_select" ON public.student_subject_stats
  FOR SELECT
  USING (
    student_id = auth.uid()
    OR public.get_my_role() IN ('admin', 'resident')
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND subject_id = public.get_my_subject_id()
    )
  );

DROP POLICY IF EXISTS "p_att_queue_select" ON public.practical_attendance_queue;
CREATE POLICY "p_att_queue_select" ON public.practical_attendance_queue
  FOR SELECT
  USING (
    resident_id = auth.uid()
    OR public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND EXISTS (
        SELECT 1
        FROM public.lectures l
        JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
        WHERE l.id = practical_attendance_queue.lecture_id
          AND ps.subject_id = public.get_my_subject_id()
      )
    )
  );

DROP POLICY IF EXISTS "p_att_queue_admin_update" ON public.practical_attendance_queue;
CREATE POLICY "p_att_queue_admin_update" ON public.practical_attendance_queue
  FOR UPDATE
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND EXISTS (
        SELECT 1
        FROM public.lectures l
        JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
        WHERE l.id = practical_attendance_queue.lecture_id
          AND ps.subject_id = public.get_my_subject_id()
      )
    )
  )
  WITH CHECK (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role()::text = 'mini_admin'
      AND EXISTS (
        SELECT 1
        FROM public.lectures l
        JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
        WHERE l.id = practical_attendance_queue.lecture_id
          AND ps.subject_id = public.get_my_subject_id()
      )
    )
  );

-- 6) Queue review functions: allow mini_admin only for own subject
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

    IF v_queue_subject IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.user_subject_assignments usa
      WHERE usa.user_id = v_uid
        AND usa.subject_id = v_queue_subject
    ) THEN
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

    IF v_queue_subject IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.user_subject_assignments usa
      WHERE usa.user_id = v_uid
        AND usa.subject_id = v_queue_subject
    ) THEN
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
