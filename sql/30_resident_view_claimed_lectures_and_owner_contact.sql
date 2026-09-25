-- ============================================================
-- StageLink — Step 30: Residents can see claimed lectures in same subject
--                    + access owner contact for WhatsApp handover
-- ============================================================
-- Goal:
--   1) Resident should see today's lecture card even when claimed by another resident
--      (as long as they are assigned to the same subject).
--   2) Resident should be able to read owner resident name/phone for handover contact
--      in the same subject scope.

-- 1) Expand lectures SELECT policy for residents (remove owner-only visibility)
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
      )
    )
  );

-- 2) Expand profiles SELECT policy so resident can read resident contact
--    only for residents sharing at least one assigned subject.
DROP POLICY IF EXISTS "profiles_select" ON public.profiles;
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT
  USING (
    id = auth.uid()
    OR public.get_my_role() = 'admin'
    OR (
      public.get_my_role() = 'resident'
      AND role = 'student'
    )
    OR (
      public.get_my_role() = 'resident'
      AND role = 'resident'
      AND EXISTS (
        SELECT 1
        FROM public.user_subject_assignments me
        JOIN public.user_subject_assignments other
          ON other.subject_id = me.subject_id
        WHERE me.user_id = auth.uid()
          AND other.user_id = profiles.id
      )
    )
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

-- 3) Secure helper RPC: resident fetches current lecture owner contact
--    (only if resident is assigned to the same subject)
CREATE OR REPLACE FUNCTION public.get_lecture_owner_contact_for_handover(
  p_lecture_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_role user_role;
  v_owner_id UUID;
  v_subject_id UUID;
  v_owner_name TEXT;
  v_owner_phone TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'unauthorized');
  END IF;

  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = v_uid;

  IF v_role IS DISTINCT FROM 'resident'::user_role THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;

  SELECT l.resident_id, ps.subject_id
  INTO v_owner_id, v_subject_id
  FROM public.lectures l
  JOIN public.practical_sessions ps
    ON ps.id = l.practical_session_id
  WHERE l.id = p_lecture_id;

  IF v_subject_id IS NULL THEN
    RETURN jsonb_build_object('status', 'lecture_not_found');
  END IF;

  IF NOT public.has_subject_assignment(v_uid, v_subject_id) THEN
    RETURN jsonb_build_object('status', 'forbidden_subject');
  END IF;

  IF v_owner_id IS NULL THEN
    RETURN jsonb_build_object('status', 'unclaimed');
  END IF;

  SELECT p.full_name, p.phone_number
  INTO v_owner_name, v_owner_phone
  FROM public.profiles p
  WHERE p.id = v_owner_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'resident_id', v_owner_id,
    'resident_name', v_owner_name,
    'resident_phone', v_owner_phone
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_lecture_owner_contact_for_handover(UUID)
TO authenticated;
