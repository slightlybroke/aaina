-- Independent VTO jobs; never alter existing analysis or skincare records.
create table public.vto_jobs (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key uuid not null,
  image_sha256 text not null,
  options jsonb not null,
  consent_version text not null check (consent_version = 'makeup-vto-v1'),
  consented_at timestamptz not null default now(),
  source_path text not null unique,
  result_path text not null unique,
  status text not null default 'uploading' check(status in ('uploading','pending','submitting','processing','completed','failed','expired')),
  external_task_id text,
  error_code text,
  attempts integer not null default 0,
  next_poll_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  source_cleanup text not null default 'pending' check(source_cleanup in ('pending','failed','deleted')),
  result_cleanup text not null default 'pending' check(result_cleanup in ('pending','failed','deleted')),
  cleanup_error text,
  cleanup_attempts integer not null default 0,
  cleanup_next_at timestamptz not null default now(),
  cleanup_verified boolean not null default false,
  unique(user_id,idempotency_key),
  check(source_path = user_id::text || '/' || id::text || '/source.jpg'),
  check(result_path = user_id::text || '/' || id::text || '/preview.jpg')
);
create index vto_work on public.vto_jobs(next_poll_at) where status not in ('completed','failed','expired');
create index vto_cleanup on public.vto_jobs(cleanup_next_at) where not cleanup_verified;
create index vto_history on public.vto_jobs(user_id,created_at desc);
alter table public.vto_jobs enable row level security;
revoke all on public.vto_jobs from anon,authenticated;
grant select on public.vto_jobs to authenticated;
grant all on public.vto_jobs to service_role;
create policy vto_read_own on public.vto_jobs for select to authenticated using ((select auth.uid())=user_id);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('vto-images','vto-images',false,10000000,array['image/jpeg']);
-- No client Storage policies: source and preview are accessible only through owner-authenticated backend.

create function public.claim_vto_job(p_token uuid) returns setof public.vto_jobs
language sql security definer set search_path=public as $$
  update public.vto_jobs set lease_token=p_token,lease_until=now()+interval '180 seconds',updated_at=now()
  where id=(select id from public.vto_jobs where status in ('pending','submitting','processing')
    and next_poll_at<=now() and expires_at>now() and (lease_until is null or lease_until<now())
    order by next_poll_at for update skip locked limit 1) returning *;
$$;
create function public.complete_vto_job(p_job uuid,p_token uuid) returns boolean
language plpgsql security definer set search_path=public as $$
begin
  update public.vto_jobs set status='completed',lease_token=null,lease_until=null,updated_at=now(),cleanup_next_at=now()
  where id=p_job and status='processing' and lease_token=p_token and lease_until>now() and expires_at>now();
  return found;
end;
$$;
create function public.expire_vto_jobs() returns void
language sql security definer set search_path=public as $$
  update public.vto_jobs set status='expired',error_code='job_expired',lease_token=null,lease_until=null,
  updated_at=now(),cleanup_next_at=now() where status not in ('completed','failed','expired') and expires_at<=now();
$$;
revoke all on function public.claim_vto_job(uuid),public.complete_vto_job(uuid,uuid),public.expire_vto_jobs() from public,anon,authenticated;
grant execute on function public.claim_vto_job(uuid),public.complete_vto_job(uuid,uuid),public.expire_vto_jobs() to service_role;
