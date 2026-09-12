-- ============================================================
-- StageLink — Step 2: Tables
-- ============================================================

-- ─── PROFILES (extends auth.users) ───────────────────────────
CREATE TABLE public.profiles (
  id            UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role          user_role   NOT NULL,
  full_name     TEXT        NOT NULL DEFAULT '',
  university_id TEXT        UNIQUE,
  category_id   UUID,                        -- FK added after categories is created
  subject_id    UUID,                        -- resident's subject (nullable for students)
  order_number  INT,                         -- sequential order within category (for auto-assign)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── YEARS ───────────────────────────────────────────────────
CREATE TABLE public.years (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name         TEXT NOT NULL,                -- e.g. "السنة الرابعة"
  year_number  INT  NOT NULL UNIQUE,         -- 4, 5, 6 …
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── CATEGORIES (student groups) ─────────────────────────────
CREATE TABLE public.categories (
  id            UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  name          TEXT        NOT NULL,        -- e.g. "المجموعة أ"
  year_id       UUID        NOT NULL REFERENCES public.years(id) ON DELETE CASCADE,
  academic_year TEXT        NOT NULL DEFAULT '2025-2026',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Now add the FK from profiles → categories
ALTER TABLE public.profiles
  ADD CONSTRAINT fk_profiles_category
  FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE SET NULL;

ALTER TABLE public.profiles
  ADD CONSTRAINT fk_profiles_subject
  FOREIGN KEY (subject_id) REFERENCES public.subjects(id) ON DELETE SET NULL;

-- ─── SUBJECTS (each subject = one "stage") ───────────────────
CREATE TABLE public.subjects (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  name        TEXT        NOT NULL,          -- e.g. "ستاج الجراحة"
  year_id     UUID        NOT NULL REFERENCES public.years(id) ON DELETE CASCADE,
  description TEXT,
  location    TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── VIDEOS ──────────────────────────────────────────────────
CREATE TABLE public.videos (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  subject_id       UUID        NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  title            TEXT        NOT NULL,
  youtube_video_id TEXT        NOT NULL,     -- only the YouTube ID, not full URL
  duration_seconds INT         NOT NULL DEFAULT 0,
  order_index      INT         NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── THEORETICAL SCHEDULES ───────────────────────────────────
-- Maps a category to a subject for a date range
CREATE TABLE public.theoretical_schedules (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  category_id UUID        NOT NULL REFERENCES public.categories(id) ON DELETE CASCADE,
  subject_id  UUID        NOT NULL REFERENCES public.subjects(id)  ON DELETE CASCADE,
  start_date  DATE        NOT NULL,
  end_date    DATE        NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (category_id, subject_id)           -- one schedule per category per subject
);

-- ─── VIDEO ATTENDANCE ────────────────────────────────────────
CREATE TABLE public.video_attendance (
  id           UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  student_id   UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  video_id     UUID        NOT NULL REFERENCES public.videos(id)   ON DELETE CASCADE,
  is_completed BOOLEAN     NOT NULL DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (student_id, video_id)
);

-- ─── PRACTICAL SESSIONS ──────────────────────────────────────
-- A session is a topic within a subject's practical component
CREATE TABLE public.practical_sessions (
  id                    UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  subject_id            UUID        NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  title                 TEXT        NOT NULL,     -- e.g. "جلسة الخياطة الجراحية"
  description           TEXT,
  order_index           INT         NOT NULL DEFAULT 0,
  prerequisite_video_id UUID        REFERENCES public.videos(id) ON DELETE SET NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── LECTURES ────────────────────────────────────────────────
-- A lecture is one physical instance of a practical session
-- (multiple lectures per session to spread students)
CREATE TABLE public.lectures (
  id                      UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  practical_session_id    UUID        NOT NULL REFERENCES public.practical_sessions(id) ON DELETE CASCADE,
  resident_id             UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  start_at                TIMESTAMPTZ NOT NULL,
  end_at                  TIMESTAMPTZ NOT NULL,
  attendance_window_start TIMESTAMPTZ NOT NULL,  -- QR scan opens
  attendance_window_end   TIMESTAMPTZ NOT NULL,  -- QR scan closes
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── LECTURE ASSIGNMENTS ─────────────────────────────────────
-- Auto-distribution result: which student goes to which lecture
CREATE TABLE public.lecture_assignments (
  id                   UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  student_id           UUID        NOT NULL REFERENCES public.profiles(id)            ON DELETE CASCADE,
  lecture_id           UUID        NOT NULL REFERENCES public.lectures(id)            ON DELETE CASCADE,
  practical_session_id UUID        NOT NULL REFERENCES public.practical_sessions(id)  ON DELETE CASCADE,
  assigned_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (student_id, lecture_id),             -- no duplicate assignment to same lecture
  UNIQUE (student_id, practical_session_id)    -- student attends exactly ONE lecture per session
);

-- ─── PRACTICAL ATTENDANCE ────────────────────────────────────
-- Recorded when resident scans student QR
CREATE TABLE public.practical_attendance (
  id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  student_id UUID        NOT NULL REFERENCES public.profiles(id)  ON DELETE CASCADE,
  lecture_id UUID        NOT NULL REFERENCES public.lectures(id)  ON DELETE CASCADE,
  scanned_by UUID        NOT NULL REFERENCES public.profiles(id)  ON DELETE SET NULL,
  scanned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (student_id, lecture_id)              -- cannot be marked present twice
);
