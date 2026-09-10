// ============================================================
// StageLink Edge Function: create-user
// Creates a student, resident, or mini-admin account via Supabase Admin API
// Only callable by users with role='admin'
// ============================================================
// Deploy: supabase functions deploy create-user --project-ref tbjgdntdiknifliyybmc
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ── 1. Verify caller is admin ──────────────────────────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return json({ error: "Missing authorization header" }, 401);
    }

    const supabaseUrl   = Deno.env.get("SUPABASE_URL")!;
    const serviceKey    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey       = Deno.env.get("SUPABASE_ANON_KEY")!;

    // Client that respects caller's JWT (for role check)
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user: caller }, error: callerErr } = await callerClient.auth.getUser();
    if (callerErr || !caller) return json({ error: "Unauthorized" }, 401);

    const { data: callerProfile, error: profileErr } = await callerClient
      .from("profiles")
      .select("role")
      .eq("id", caller.id)
      .single();

    if (profileErr || callerProfile?.role !== "admin") {
      return json({ error: "Forbidden: admin only" }, 403);
    }

    // ── 2. Parse body ──────────────────────────────────────
    const body = await req.json();
    const {
      username,
      full_name,
      university_id,
      gender,
      role,          // "student" | "resident" | "mini_admin" (never "admin")
      category_id,   // required for student
      order_number,  // required for student
      subject_id,    // required for resident
    } = body;

    // Validate role — admin accounts can NEVER be created here
    if (!["student", "resident", "mini_admin"].includes(role)) {
      return json({ error: "Invalid role. Only 'student', 'resident', or 'mini_admin' allowed." }, 400);
    }

    if (!username || !full_name) {
      return json({ error: "Missing required fields: username, full_name" }, 400);
    }

    const normalizedUsername = String(username).trim().toLowerCase();
    if (!/^[a-z0-9._-]{4,32}$/.test(normalizedUsername)) {
      return json({ error: "username must be 4-32 chars (a-z, 0-9, ., _, -)" }, 400);
    }

    const authEmail = `${normalizedUsername}@stagelink.local`;
    const generatedPassword = generateStrongPassword(16);

    if (role === "student" && !university_id) {
      return json({ error: "university_id is required for students" }, 400);
    }

    if (role === "student" && !category_id) {
      return json({ error: "category_id is required for students" }, 400);
    }

    if (role === "student" && !["male", "female"].includes(String(gender))) {
      return json({ error: "gender is required for students and must be 'male' or 'female'" }, 400);
    }

    if ((role === "resident" || role === "mini_admin") && !subject_id) {
      return json({ error: "subject_id is required for residents and mini_admin" }, 400);
    }

    // ── 3. Create auth user with service_role ──────────────
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: existingUsername } = await adminClient
      .from("profiles")
      .select("id")
      .eq("username", normalizedUsername)
      .maybeSingle();

    if (existingUsername?.id) {
      return json({ error: "اسم المستخدم مستخدم مسبقاً" }, 400);
    }

    const { data: newUser, error: createErr } = await adminClient.auth.admin.createUser({
      email: authEmail,
      password: generatedPassword,
      email_confirm: true,
      user_metadata: {
        role,
        username: normalizedUsername,
        full_name,
        university_id: role === "student" ? university_id : null,
        gender: role === "student" ? gender : null,
      },
    });

    if (createErr) {
      return json({ error: createErr.message }, 400);
    }

    // ── 4. Update profile with extra fields ───────────────
    const profileUpdate: Record<string, unknown> = {
      username: normalizedUsername,
      auth_email: authEmail,
      login_enabled: true,
      login_activated: false,
      login_reset_mode: "none",
    };
    if (role === "student") {
      profileUpdate.category_id  = category_id;
      profileUpdate.order_number = order_number ?? null;
      profileUpdate.gender = gender;
    }
    if (role === "resident" || role === "mini_admin") {
      profileUpdate.subject_id = subject_id;
    }

    if (Object.keys(profileUpdate).length > 0) {
      await adminClient
        .from("profiles")
        .update(profileUpdate)
        .eq("id", newUser.user!.id);
    }

    return json(
      {
        user_id: newUser.user!.id,
        username: normalizedUsername,
        password: generatedPassword,
        message: "User created successfully",
      },
      201,
    );

  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Internal server error";
    return json({ error: message }, 500);
  }
});

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function generateStrongPassword(length = 16): string {
  const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const lower = "abcdefghijkmnopqrstuvwxyz";
  const digits = "23456789";
  const symbols = "!@#%^&*()-_=+[]{}";
  const all = upper + lower + digits + symbols;

  const chars: string[] = [];
  chars.push(upper[Math.floor(Math.random() * upper.length)]);
  chars.push(lower[Math.floor(Math.random() * lower.length)]);
  chars.push(digits[Math.floor(Math.random() * digits.length)]);
  chars.push(symbols[Math.floor(Math.random() * symbols.length)]);

  for (let i = chars.length; i < Math.max(length, 12); i++) {
    chars.push(all[Math.floor(Math.random() * all.length)]);
  }

  for (let i = chars.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }

  return chars.join("");
}
