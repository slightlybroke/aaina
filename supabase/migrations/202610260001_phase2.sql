-- Forward-only Phase 2. Phase 1 tables, functions and Storage are untouched.
begin;
create table public.skincare_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  timezone text not null default 'UTC',
  updated_at timestamptz not null default now()
);
create table public.routines (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(id, user_id)
);
-- Append-only revisions. Edits start tomorrow; multiple future edits are ordered by version.
-- Step UUIDs and their order live in the revision document, not a product catalogue.
create table public.routine_revisions (
  id uuid primary key default gen_random_uuid(),
  routine_id uuid not null,
  user_id uuid not null,
  version integer not null check(version > 0),
  effective_from date not null,
  definition jsonb not null check(jsonb_typeof(definition) = 'object'
    and definition->>'status' in ('active','paused','archived')
    and definition->>'kind' in ('morning','evening','custom')
    and length(definition->>'name') between 1 and 100
    and jsonb_array_length(definition->'steps') between 1 and 30
    and jsonb_array_length(definition->'days') between 1 and 7),
  created_at timestamptz not null default now(),
  unique(routine_id, version), unique(id, routine_id, user_id),
  foreign key(routine_id,user_id) references public.routines(id,user_id) on delete cascade
);
create table public.routine_checkins (
  id uuid primary key default gen_random_uuid(),
  routine_id uuid not null,
  user_id uuid not null,
  revision_id uuid not null,
  local_date date not null,
  completed_steps jsonb not null check(jsonb_typeof(completed_steps)='array'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(routine_id,local_date),
  foreign key(revision_id,routine_id,user_id)
    references public.routine_revisions(id,routine_id,user_id)
);
create table public.skin_journal (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  concerns jsonb not null check(jsonb_typeof(concerns)='array'
    and jsonb_array_length(concerns) between 1 and 8),
  severity text check(severity in ('mild','moderate','severe')),
  notes text not null default '' check(length(notes)<=3000),
  observed_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index routine_owner on public.routines(user_id,created_at);
create index revision_owner_date on public.routine_revisions(user_id,routine_id,effective_from,version);
create index checkin_owner_date on public.routine_checkins(user_id,local_date);
create index journal_owner_date on public.skin_journal(user_id,observed_at desc);

alter table public.skincare_settings enable row level security;
alter table public.routines enable row level security;
alter table public.routine_revisions enable row level security;
alter table public.routine_checkins enable row level security;
alter table public.skin_journal enable row level security;
revoke all on public.skincare_settings, public.routines, public.routine_revisions,
  public.routine_checkins, public.skin_journal from anon, authenticated;
grant select on public.skincare_settings, public.routines, public.routine_revisions,
  public.routine_checkins, public.skin_journal to authenticated;
grant all on public.skincare_settings, public.routines, public.routine_revisions,
  public.routine_checkins, public.skin_journal to service_role;
create policy settings_read_own on public.skincare_settings for select to authenticated
  using((select auth.uid())=user_id);
create policy routines_read_own on public.routines for select to authenticated
  using((select auth.uid())=user_id);
create policy revisions_read_own on public.routine_revisions for select to authenticated
  using((select auth.uid())=user_id);
create policy checkins_read_own on public.routine_checkins for select to authenticated
  using((select auth.uid())=user_id);
create policy journal_read_own on public.skin_journal for select to authenticated
  using((select auth.uid())=user_id);

-- Only the verified backend can call this transaction boundary. Never expose it to clients.
-- Per-owner transaction lock serializes settings, revision edits and check-in snapshots.
create function public.skincare_write(p_user uuid, p_action text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  tz text; today date; target uuid; r public.routine_revisions;
  entry public.routine_checkins; result jsonb; latest integer; day date;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_user::text, 2));
  select timezone into tz from public.skincare_settings where user_id=p_user;
  tz := coalesce(tz,'UTC');
  today := (now() at time zone tz)::date;
  if p_action='settings' then
    if not exists(select 1 from pg_timezone_names where name=p_data->>'timezone') then
      return jsonb_build_object('error','Invalid IANA timezone.','status',422);
    end if;
    if tz <> p_data->>'timezone' and exists(select 1 from public.routines where user_id=p_user) then
      return jsonb_build_object('error','Timezone is fixed once routines exist to preserve daily history.','status',409);
    end if;
    insert into public.skincare_settings(user_id,timezone) values(p_user,p_data->>'timezone')
      on conflict(user_id) do update set timezone=excluded.timezone, updated_at=now();
    return jsonb_build_object('timezone',p_data->>'timezone');
  end if;
  target := (p_data->>'id')::uuid;
  if p_action='routine' then
    select * into r from public.routine_revisions where routine_id=target and user_id=p_user
      order by version desc limit 1;
    if found then
      if r.id::text is distinct from p_data->>'expected_revision' then
        return jsonb_build_object('error','Routine changed. Reload before editing.','status',409);
      end if;
      latest := r.version+1; day := today+1;
    else
      if p_data->>'expected_revision' is not null then
        return jsonb_build_object('error','Routine not found.','status',404);
      end if;
      if exists(select 1 from public.routines where id=target) then
        return jsonb_build_object('error','Routine not found.','status',404);
      end if;
      if (select count(*) from public.routines where user_id=p_user)>=100 then
        return jsonb_build_object('error','Routine limit reached (100).','status',422);
      end if;
      insert into public.routines(id,user_id) values(target,p_user);
      latest := 1; day := today;
    end if;
    insert into public.routine_revisions(routine_id,user_id,version,effective_from,definition)
      values(target,p_user,latest,day,p_data->'definition') returning to_jsonb(routine_revisions.*) into result;
    return result;
  elsif p_action='checkin' then
    day := (p_data->>'local_date')::date;
    if day>today then return jsonb_build_object('error','Future check-ins are not allowed.','status',422); end if;
    select * into r from public.routine_revisions where routine_id=target and user_id=p_user
      and effective_from<=day order by effective_from desc,version desc limit 1;
    if not found then return jsonb_build_object('error','Routine not found for this date.','status',404); end if;
    if r.id::text is distinct from p_data->>'revision_id' then
      return jsonb_build_object('error','Routine changed. Reload this date.','status',409);
    end if;
    if r.definition->>'status'<>'active' or not (r.definition->'days' @> to_jsonb(extract(isodow from day)::integer)) then
      return jsonb_build_object('error','Routine is not scheduled for this date.','status',422);
    end if;
    if exists(select 1 from jsonb_array_elements_text(p_data->'completed_steps') x
      where not exists(select 1 from jsonb_array_elements(r.definition->'steps') s where s->>'id'=x)) then
      return jsonb_build_object('error','Unknown step. Reload this routine.','status',422);
    end if;
    insert into public.routine_checkins(routine_id,user_id,revision_id,local_date,completed_steps)
      values(target,p_user,r.id,day,p_data->'completed_steps')
      on conflict(routine_id,local_date) do update set completed_steps=excluded.completed_steps,updated_at=now()
      returning to_jsonb(routine_checkins.*) into result;
    return result;
  elsif p_action='journal' then
    if (p_data->>'observed_at')::timestamptz>now()+interval '1 minute' then
      return jsonb_build_object('error','Observation cannot be in the future.','status',422);
    end if;
    if exists(select 1 from public.skin_journal where id=target and user_id<>p_user) then
      return jsonb_build_object('error','Entry not found.','status',404);
    end if;
    insert into public.skin_journal(id,user_id,concerns,severity,notes,observed_at)
      values(target,p_user,p_data->'concerns',p_data->>'severity',p_data->>'notes',(p_data->>'observed_at')::timestamptz)
      on conflict(id) do update set concerns=excluded.concerns,severity=excluded.severity,
        notes=excluded.notes,observed_at=excluded.observed_at,updated_at=now()
      returning to_jsonb(skin_journal.*) into result;
    return result;
  elsif p_action='journal_delete' then
    delete from public.skin_journal where id=target and user_id=p_user;
    if not found then return jsonb_build_object('error','Entry not found.','status',404); end if;
    return jsonb_build_object('deleted',true);
  end if;
  raise exception 'Unsupported skincare operation';
end;
$$;
revoke all on function public.skincare_write(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.skincare_write(uuid,text,jsonb) to service_role;
commit;
