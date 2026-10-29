-- Apply to a Supabase project. No public access to selfies or client writes to jobs.
create table public.analysis_jobs (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key uuid not null,
  image_sha256 text not null,
  image_path text not null unique,
  consent_version text not null check (consent_version = 'skin-analysis-v1'),
  consented_at timestamptz not null default now(),
  status text not null default 'uploading' check (status in
    ('uploading','pending','submitting','processing','completed','failed','expired')),
  external_task_id text,
  error_code text,
  attempts integer not null default 0,
  next_poll_at timestamptz not null default now(),
  lease_until timestamptz,
  lease_token uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  image_delete_after timestamptz not null,
  cleanup_status text not null default 'pending' check (cleanup_status in ('pending','failed','deleted')),
  cleanup_attempts integer not null default 0,
  cleanup_error text,
  cleanup_next_at timestamptz not null default now(),
  unique (user_id, idempotency_key),
  unique (id, user_id),
  check (image_path = user_id::text || '/' || id::text || '/source.jpg')
);
create table public.skin_analyses (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  overall_score double precision not null check (overall_score between 1 and 100),
  metrics jsonb not null,
  warnings jsonb not null default '[]',
  api_version text not null default '2.1',
  response_format text not null default 'zip',
  contract_verification text not null default 'documentation_only',
  analyzed_at timestamptz not null default now(),
  foreign key (job_id, user_id) references public.analysis_jobs(id, user_id) on delete cascade
);
create index jobs_work on public.analysis_jobs (next_poll_at) where status not in ('completed','failed','expired');
create index jobs_cleanup on public.analysis_jobs (cleanup_next_at) where cleanup_status <> 'deleted';
create index analyses_history on public.skin_analyses (user_id, analyzed_at desc);
alter table public.analysis_jobs enable row level security;
alter table public.skin_analyses enable row level security;
revoke all on public.analysis_jobs, public.skin_analyses from anon, authenticated;
grant select on public.analysis_jobs, public.skin_analyses to authenticated;
grant all on public.analysis_jobs, public.skin_analyses to service_role;
create policy jobs_read_own on public.analysis_jobs for select to authenticated using ((select auth.uid()) = user_id);
create policy analyses_read_own on public.skin_analyses for select to authenticated using ((select auth.uid()) = user_id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('analysis-incoming', 'analysis-incoming', false, 10000000, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
allowed_mime_types = excluded.allowed_mime_types;
-- Upload/delete are server-only. Users cannot replace a queued image through Storage.
create policy incoming_read_own on storage.objects for select to authenticated using (
  bucket_id = 'analysis-incoming' and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (select 1 from public.analysis_jobs j where j.image_path = name
    and j.user_id = (select auth.uid()) and j.cleanup_status <> 'deleted'
    and j.image_delete_after > now())
);

create function public.claim_analysis_job(p_token uuid) returns setof public.analysis_jobs
language sql security definer set search_path = public as $$
  update public.analysis_jobs set lease_until = now() + interval '180 seconds', lease_token = p_token,
    updated_at = now()
  where id = (select id from public.analysis_jobs
    where status not in ('uploading','completed','failed','expired')
      and next_poll_at <= now() and (lease_until is null or lease_until < now())
    order by next_poll_at for update skip locked limit 1)
  returning *;
$$;

create function public.complete_analysis_job(p_job uuid, p_token uuid, p_score double precision,
  p_metrics jsonb, p_warnings jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare j public.analysis_jobs;
begin
  select * into j from public.analysis_jobs where id = p_job for update;
  if not found or j.status <> 'processing' or j.lease_token is distinct from p_token
    or j.lease_until is null or j.lease_until < now() or j.expires_at < now()
    then return false; end if;
  insert into public.skin_analyses (job_id, user_id, overall_score, metrics, warnings)
    values (j.id, j.user_id, p_score, p_metrics, p_warnings);
  update public.analysis_jobs set status = 'completed', updated_at = now(), lease_until = null,
    lease_token = null, image_delete_after = least(image_delete_after, now()) where id = j.id;
  return true;
end;
$$;

-- Expire interrupted uploads and all overdue work, including worker downtime.
create function public.expire_analysis_jobs() returns void
language sql security definer set search_path = public as $$
  update public.analysis_jobs set status = 'expired', error_code = 'job_expired',
    image_delete_after = least(image_delete_after, now()), updated_at = now(),
    lease_until = null, lease_token = null
  where status not in ('completed','failed','expired') and expires_at < now();
$$;
revoke all on function public.claim_analysis_job(uuid),
  public.complete_analysis_job(uuid,uuid,double precision,jsonb,jsonb),
  public.expire_analysis_jobs() from public, anon, authenticated;
grant execute on function public.claim_analysis_job(uuid),
  public.complete_analysis_job(uuid,uuid,double precision,jsonb,jsonb),
  public.expire_analysis_jobs() to service_role;
