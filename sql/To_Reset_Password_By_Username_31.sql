create or replace function public.admin_reset_password_by_username(
  p_username text,
  p_new_password text
)
returns void
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid;
begin
  if p_username is null or length(trim(p_username)) = 0 then
    raise exception 'username is required';
  end if;

  if p_new_password is null or length(p_new_password) < 8 then
    raise exception 'password must be at least 8 characters';
  end if;

  select p.id
    into v_user_id
  from public.profiles p
  where lower(p.username) = lower(trim(p_username))
  limit 1;

  if v_user_id is null then
    raise exception 'user not found for username: %', p_username;
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(
           p_new_password,
           extensions.gen_salt('bf', 10)
         ),
         updated_at = now()
   where id = v_user_id;

  if not found then
    raise exception 'auth user not found for username: %', p_username;
  end if;
end;
$$;

revoke all on function public.admin_reset_password_by_username(text, text) from public;



-- select public.admin_reset_password_by_username('username', 'new_password');