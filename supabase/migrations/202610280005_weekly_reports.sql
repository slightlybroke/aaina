-- Weekly snapshots and their in-app unread notification are one atomic record.
create table public.weekly_reports (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 week_start date not null check(extract(isodow from week_start)=1),
 week_end date not null check(week_end=week_start+6),
 timezone text not null,
 content jsonb not null check(jsonb_typeof(content)='object'),
 generated_at timestamptz not null default now(),
 read_at timestamptz,
 unique(user_id,week_start)
);
create index weekly_owner_history on public.weekly_reports(user_id,week_start desc,id);
create index weekly_owner_unread on public.weekly_reports(user_id) where read_at is null;
alter table public.weekly_reports enable row level security;
revoke all on public.weekly_reports from anon,authenticated;
grant select on public.weekly_reports to authenticated;
grant all on public.weekly_reports to service_role;
create policy weekly_read_own on public.weekly_reports for select to authenticated
 using((select auth.uid())=user_id);
