-- ============================================================
-- StageLink — Step 3: Row Level Security Policies
-- ============================================================

-- Enable RLS on every table
ALTER TABLE public.profiles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.years                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subjects             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.videos               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.theoretical_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.video_attendance     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.practical_sessions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lectures             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lecture_assignments  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.practical_attendance ENABLE ROW LEVEL SECURITY;

-- ─── HELPER: get current user's role ─────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS user_role
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

-- ============================================================
-- PROFILES
-- ============================================================

-- SELECT: own profile | admin sees all | resident sees students
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT USING (
    id = auth.uid()
    OR public.get_my_role() = 'admin'
    OR (public.get_my_role() = 'resident' AND role = 'student')
  );

-- UPDATE: own profile only; cannot change own role
CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (role = (SELECT role FROM public.profiles WHERE id = auth.uid()));

-- INSERT / DELETE: handled exclusively by Edge Functions via service_role

-- ============================================================
-- YEARS (read: all authenticated | write: admin only)
-- ============================================================
CREATE POLICY "years_select"        ON public.years FOR SELECT TO authenticated USING (true);
CREATE POLICY "years_admin_insert"  ON public.years FOR INSERT  WITH CHECK (public.get_my_role() = 'admin');
CREATE POLICY "years_admin_update"  ON public.years FOR UPDATE  USING     (public.get_my_role() = 'admin');
CREATE POLICY "years_admin_delete"  ON public.years FOR DELETE  USING     (public.get_my_role() = 'admin');

-- ============================================================
-- CATEGORIES
-- ============================================================
CREATE POLICY "categories_select"       ON public.categories FOR SELECT TO authenticated USING (true);
CREATE POLICY "categories_admin_insert" ON public.categories FOR INSERT  WITH CHECK (public.get_my_role() = 'admin');
CREATE POLICY "categories_admin_update" ON public.categories FOR UPDATE  USING     (public.get_my_role() = 'admin');
CREATE POLICY "categories_admin_delete" ON public.categories FOR DELETE  USING     (public.get_my_role() = 'admin');

-- ============================================================
-- SUBJECTS
-- ============================================================
CREATE POLICY "subjects_select"       ON public.subjects FOR SELECT TO authenticated USING (true);
CREATE POLICY "subjects_admin_insert" ON public.subjects FOR INSERT  WITH CHECK (public.get_my_role() = 'admin');
CREATE POLICY "subjects_admin_update" ON public.subjects FOR UPDATE  USING     (public.get_my_role() = 'admin');
CREATE POLICY "subjects_admin_delete" ON public.subjects FOR DELETE  USING     (public.get_my_role() = 'admin');

-- ============================================================
-- VIDEOS
-- ============================================================
CREATE POLICY "videos_select"       ON public.videos FOR SELECT TO authenticated USING (true);
CREATE POLICY "videos_admin_insert" ON public.videos FOR INSERT  WITH CHECK (public.get_my_role() = 'admin');
CREATE POLICY "videos_admin_update" ON public.videos FOR UPDATE  USING     (public.get_my_role() = 'admin');
CREATE POLICY "videos_admin_delete" ON public.videos FOR DELETE  USING     (public.get_my_role() = 'admin');

-- ============================================================
-- THEORETICAL SCHEDULES
-- ============================================================
CREATE POLICY "schedules_select"       ON public.theoretical_schedules FOR SELECT TO authenticated USING (true);
CREATE POLICY "schedules_admin_insert" ON public.theoretical_schedules FOR INSERT  WITH CHECK (public.get_my_role() = 'admin');
CREATE POLICY "schedules_admin_update" ON public.theoretical_schedules FOR UPDATE  USING     (public.get_my_role() = 'admin');
CREATE POLICY "schedules_admin_delete" ON public.theoretical_schedules FOR DELETE  USING     (public.get_my_role() = 'admin');

-- ============================================================
-- VIDEO ATTENDANCE
-- ============================================================

-- SELECT: student sees own records | admin sees all
CREATE POLICY "video_att_select" ON public.video_attendance
  FOR SELECT USING (
    student_id = auth.uid() OR public.get_my_role() = 'admin'
  );

-- INSERT: student can only insert for themselves
CREATE POLICY "video_att_insert" ON public.video_attendance
  FOR INSERT WITH CHECK (
    student_id = auth.uid() AND public.get_my_role() = 'student'
  );

-- UPDATE: student can only update their own record
CREATE POLICY "video_att_update" ON public.video_attendance
  FOR UPDATE USING (
    student_id = auth.uid() AND public.get_my_role() = 'student'
  );

-- ============================================================
-- PRACTICAL SESSIONS
-- ============================================================
CREATE POLICY "p_sessions_select"       ON public.practical_sessions FOR SELECT TO authenticated USING (true);
CREATE POLICY "p_sessions_admin_insert" ON public.practical_sessions FOR INSERT  WITH CHECK (public.get_my_role() = 'admin');
CREATE POLICY "p_sessions_admin_update" ON public.practical_sessions FOR UPDATE  USING     (public.get_my_role() = 'admin');
CREATE POLICY "p_sessions_admin_delete" ON public.practical_sessions FOR DELETE  USING     (public.get_my_role() = 'admin');

-- ============================================================
-- LECTURES
-- ============================================================
CREATE POLICY "lectures_select"       ON public.lectures FOR SELECT TO authenticated USING (true);
CREATE POLICY "lectures_admin_insert" ON public.lectures FOR INSERT  WITH CHECK (public.get_my_role() = 'admin');
CREATE POLICY "lectures_admin_update" ON public.lectures FOR UPDATE  USING     (public.get_my_role() = 'admin');
CREATE POLICY "lectures_admin_delete" ON public.lectures FOR DELETE  USING     (public.get_my_role() = 'admin');

-- ============================================================
-- LECTURE ASSIGNMENTS
-- ============================================================

-- SELECT: own assignment | admin | resident (to see their students)
CREATE POLICY "assignments_select" ON public.lecture_assignments
  FOR SELECT USING (
    student_id = auth.uid()
    OR public.get_my_role() IN ('admin', 'resident')
  );

-- INSERT / DELETE: Edge Function only (service_role bypasses RLS)

-- ============================================================
-- PRACTICAL ATTENDANCE
-- ============================================================

-- SELECT: student sees own | resident sees what they scanned | admin sees all
CREATE POLICY "p_att_select" ON public.practical_attendance
  FOR SELECT USING (
    student_id = auth.uid()
    OR scanned_by   = auth.uid()
    OR public.get_my_role() = 'admin'
  );

-- INSERT: only resident, and scanned_by must equal their own auth id
CREATE POLICY "p_att_insert_resident" ON public.practical_attendance
  FOR INSERT WITH CHECK (
    public.get_my_role() = 'resident'
    AND scanned_by = auth.uid()
  );
