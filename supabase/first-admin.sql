-- =====================================================================
-- Make yourself the first Admin (run once, after schema.sql)
--
-- 1. Supabase dashboard -> Authentication -> Users -> "Add user"
--    -> "Create new user", enter YOUR email and a password,
--    tick "Auto Confirm User".
-- 2. Change the two values below, then run this file in the SQL Editor.
-- =====================================================================

insert into public.profiles (id, full_name, email, role, joined_at)
select id, 'Your Full Name', email, 'admin', now()
from auth.users
where email = lower('you@example.com')
on conflict (id) do update set role = 'admin', active = true;
