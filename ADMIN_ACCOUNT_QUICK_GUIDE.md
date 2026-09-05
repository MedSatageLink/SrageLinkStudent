# دليل سريع: إدارة حسابات Admin

نفّذ الأوامر التالية في Supabase SQL Editor بعد تنفيذ migration رقم 15.

> إذا ظهر خطأ `function gen_salt(unknown) does not exist` نفّذ أولاً:
```sql
create extension if not exists "pgcrypto";
```

## 1) إنشاء حساب Admin جديد (أمر واحد)
> كلمة المرور تُنشأ تلقائياً إذا مررت `NULL`.
بمعنى اتركها null وسيتم انشاء كلمة مرور تلقائية

```sql
select public.db_create_admin_account(
  p_auth_email := 'bushr@gmail.com',
  p_password   := null,
  p_username   := 'bushr',
  p_full_name  := 'Bushr Alayed'
);
```

- النتيجة سترجع: `user_id`, `username`, `auth_email`, `password`.
- خذ `password` واحفظها مباشرة.
فيكون تسجيل الدخول على تطبيق الادمن من خلال كلمة المرور التي حصلت عليها والويزرنيم bushr

## 2) حذف حساب Admin (أمر واحد)
```sql
select public.db_delete_admin_account('bushr');
```

## 3) إعادة تفعيل حساب Admin مقيدة (نفس الجهاز) — أمر واحد
```sql
select public.db_reset_admin_login(
  p_admin_user_id := 'PUT-ADMIN-USER-ID-HERE',
  p_mode := 'same_device'
);
```

## 4) إعادة تفعيل حساب Admin حرة (جهاز جديد) — أمر واحد
```sql
select public.db_reset_admin_login(
  p_admin_user_id := 'PUT-ADMIN-USER-ID-HERE',
  p_mode := 'any_device'
);
```

## كيف أحصل على `admin_user_id` بسرعة؟
```sql
select id, username, auth_email
from public.profiles
where role = 'admin'
order by created_at desc;
```
