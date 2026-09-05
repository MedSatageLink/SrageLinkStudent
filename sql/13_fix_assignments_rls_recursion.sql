-- ============================================================
-- StageLink — Hotfix: break RLS recursion between lectures/assignments
-- Run this if migration 12 was already applied.
-- ============================================================

-- Remove both new and legacy policies first (idempotent)
DROP POLICY IF EXISTS "assignments_select" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Admins manage lecture_assignments" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Students view own lecture assignments" ON public.lecture_assignments;
DROP POLICY IF EXISTS "Residents view assignments for their lectures" ON public.lecture_assignments;

-- Explicit non-recursive policies
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
