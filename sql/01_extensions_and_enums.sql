-- ============================================================
-- StageLink — Step 1: Extensions & Enums
-- Run this FIRST before all other scripts
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable cryptographic utilities
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- User role enum (safe idempotent creation)
DO $$
BEGIN
  CREATE TYPE user_role AS ENUM ('admin', 'resident', 'student');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
