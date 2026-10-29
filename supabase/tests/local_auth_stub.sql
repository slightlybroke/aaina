-- LOCAL EMPTY TEST DATABASE ONLY. Not a Supabase migration; never run remotely.
-- Used to execute Phase 2 SQL offline without claiming real Auth validation.
create role anon;
create role authenticated;
create role service_role bypassrls;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
insert into auth.users values(gen_random_uuid()),(gen_random_uuid());
