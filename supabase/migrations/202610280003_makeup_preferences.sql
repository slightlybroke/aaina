-- Minimal Phase 4 profile context; explicit settings only, no conversation capture.
create table public.makeup_preferences (
 user_id uuid primary key references auth.users(id) on delete cascade,
 preferred_shade text not null default '' check(length(preferred_shade)<=120),
 preferred_finish text not null default '' check(length(preferred_finish)<=80),
 excluded_categories jsonb not null default '[]' check(jsonb_typeof(excluded_categories)='array' and jsonb_array_length(excluded_categories)<=12),
 source text not null default 'explicit_profile' check(source='explicit_profile'),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.makeup_preferences enable row level security;
revoke all on public.makeup_preferences from anon,authenticated;
grant select on public.makeup_preferences to authenticated;
grant all on public.makeup_preferences to service_role;
create policy makeup_preferences_read_own on public.makeup_preferences for select to authenticated
using((select auth.uid())=user_id);
