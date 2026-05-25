-- ═══════════════════════════════════════════════════════════
-- Migration v2: Redesign lectures, remove order_index, add schedule
-- Run this in Supabase SQL Editor → "Run and enable RLS"
-- ═══════════════════════════════════════════════════════════

-- 1. Remove order_index from videos
ALTER TABLE videos DROP COLUMN IF EXISTS order_index;

-- 2. Remove order_index from practical_sessions
ALTER TABLE practical_sessions DROP COLUMN IF EXISTS order_index;

-- 3. Remove max_capacity from lectures
ALTER TABLE lectures DROP COLUMN IF EXISTS max_capacity;

-- 3.1 Add subject_id to profiles for residents
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS subject_id uuid;
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM   information_schema.table_constraints
    WHERE  table_schema = 'public'
    AND    table_name = 'profiles'
    AND    constraint_name = 'fk_profiles_subject'
  ) THEN
    ALTER TABLE profiles
      ADD CONSTRAINT fk_profiles_subject
      FOREIGN KEY (subject_id) REFERENCES public.subjects(id) ON DELETE SET NULL;
  END IF;
END $$;

-- 3.1 Switch lectures date/time to start_at/end_at
ALTER TABLE lectures ADD COLUMN IF NOT EXISTS start_at timestamptz;
ALTER TABLE lectures ADD COLUMN IF NOT EXISTS end_at timestamptz;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'lectures' AND column_name = 'date'
  ) AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'lectures' AND column_name = 'time'
  ) THEN
    UPDATE public.lectures
    SET start_at = COALESCE(start_at, (date::timestamptz + time)),
        end_at   = COALESCE(end_at,   (date::timestamptz + time));
  END IF;
END $$;

ALTER TABLE lectures ALTER COLUMN start_at SET NOT NULL;
ALTER TABLE lectures ALTER COLUMN end_at SET NOT NULL;
ALTER TABLE lectures DROP COLUMN IF EXISTS date;
ALTER TABLE lectures DROP COLUMN IF EXISTS time;

-- 4. Create lecture_assignments table (admin assigns students to specific lectures)
CREATE TABLE IF NOT EXISTS lecture_assignments (
  id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  lecture_id  uuid REFERENCES lectures(id) ON DELETE CASCADE NOT NULL,
  student_id  uuid REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  created_at  timestamptz DEFAULT now(),
  UNIQUE(lecture_id, student_id)
);
ALTER TABLE lecture_assignments ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='lecture_assignments' AND policyname='Admins manage lecture_assignments'
  ) THEN
    CREATE POLICY "Admins manage lecture_assignments" ON lecture_assignments
      USING ((SELECT role FROM profiles WHERE id = auth.uid()) = 'admin')
      WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid()) = 'admin');
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='lecture_assignments' AND policyname='Students view own lecture assignments'
  ) THEN
    CREATE POLICY "Students view own lecture assignments" ON lecture_assignments
      FOR SELECT USING (student_id = auth.uid());
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='lecture_assignments' AND policyname='Residents view assignments for their lectures'
  ) THEN
    CREATE POLICY "Residents view assignments for their lectures" ON lecture_assignments
      FOR SELECT USING (
        lecture_id IN (SELECT id FROM lectures WHERE resident_id = auth.uid())
      );
  END IF;
END $$;

-- 5. Create theoretical_schedules table (when each category watches each subject's videos)
CREATE TABLE IF NOT EXISTS theoretical_schedules (
  id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  category_id uuid REFERENCES categories(id) ON DELETE CASCADE NOT NULL,
  subject_id  uuid REFERENCES subjects(id)   ON DELETE CASCADE NOT NULL,
  start_date  date NOT NULL,
  end_date    date,
  created_at  timestamptz DEFAULT now(),
  UNIQUE(category_id, subject_id)
);

-- Add end_date if table already exists (safe to run again)
ALTER TABLE theoretical_schedules ADD COLUMN IF NOT EXISTS end_date date;
ALTER TABLE theoretical_schedules ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='theoretical_schedules' AND policyname='Admins manage theoretical_schedules'
  ) THEN
    CREATE POLICY "Admins manage theoretical_schedules" ON theoretical_schedules
      USING ((SELECT role FROM profiles WHERE id = auth.uid()) = 'admin')
      WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid()) = 'admin');
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='theoretical_schedules' AND policyname='Students view their schedule'
  ) THEN
    CREATE POLICY "Students view their schedule" ON theoretical_schedules
      FOR SELECT USING (
        category_id IN (SELECT category_id FROM profiles WHERE id = auth.uid())
      );
  END IF;
END $$;

-- 6. Index for performance
CREATE INDEX IF NOT EXISTS idx_lecture_assignments_student ON lecture_assignments(student_id);
CREATE INDEX IF NOT EXISTS idx_lecture_assignments_lecture ON lecture_assignments(lecture_id);
CREATE INDEX IF NOT EXISTS idx_theoretical_schedules_category ON theoretical_schedules(category_id);
CREATE INDEX IF NOT EXISTS idx_videos_created_at ON videos(created_at);
CREATE INDEX IF NOT EXISTS idx_practical_sessions_created_at ON practical_sessions(created_at);
