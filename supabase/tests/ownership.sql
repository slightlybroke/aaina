-- Run in a dedicated development Supabase project after applying the migration.
-- Requires two existing auth.users. All fixture changes are rolled back.
begin;
do $$
declare a uuid; b uuid;
begin
  select id into a from auth.users order by created_at limit 1;
  select id into b from auth.users where id <> a order by created_at limit 1;
  if b is null then raise exception 'Create two development users before running isolation tests'; end if;
  perform set_config('test.user_a', a::text, true);
  perform set_config('test.user_b', b::text, true);
end $$;
insert into public.analysis_jobs
  (id,user_id,idempotency_key,image_sha256,image_path,consent_version,expires_at,image_delete_after)
select '11111111-1111-4111-8111-111111111111'::uuid, current_setting('test.user_a')::uuid,
  gen_random_uuid(), 'test', current_setting('test.user_a') || '/11111111-1111-4111-8111-111111111111/source.jpg',
  'skin-analysis-v1', now()+interval '30 minutes', now()+interval '1 hour'
union all
select '22222222-2222-4222-8222-222222222222'::uuid, current_setting('test.user_b')::uuid,
  gen_random_uuid(), 'test', current_setting('test.user_b') || '/22222222-2222-4222-8222-222222222222/source.jpg',
  'skin-analysis-v1', now()+interval '30 minutes', now()+interval '1 hour';
insert into public.skin_analyses (job_id,user_id,overall_score,metrics)
select id,user_id,70,'[]'::jsonb from public.analysis_jobs
where id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
-- Storage metadata fixtures only; no real image is written.
insert into storage.objects (bucket_id,name)
select 'analysis-incoming', image_path from public.analysis_jobs
where id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.user_a'),true);
select set_config('request.jwt.claims',json_build_object('sub',current_setting('test.user_a'),'role','authenticated')::text,true);
do $$ begin
  if (select count(*) from public.analysis_jobs where id in
    ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222')) <> 1
    then raise exception 'Job ownership isolation failed'; end if;
  if exists(select 1 from public.skin_analyses where user_id <> auth.uid())
    then raise exception 'Analysis ownership isolation failed'; end if;
  if (select count(*) from storage.objects where bucket_id='analysis-incoming' and name like '%/source.jpg'
    and name in (current_setting('test.user_a')||'/11111111-1111-4111-8111-111111111111/source.jpg',
      current_setting('test.user_b')||'/22222222-2222-4222-8222-222222222222/source.jpg')) <> 1
    then raise exception 'Storage ownership isolation failed'; end if;
  begin
    update public.analysis_jobs set status='pending' where user_id=auth.uid();
    raise exception 'Client job update unexpectedly permitted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.claim_analysis_job(gen_random_uuid());
    raise exception 'Client worker RPC unexpectedly permitted';
  exception when insufficient_privilege then null; end;
  begin
    insert into storage.objects(bucket_id,name) values('analysis-incoming', auth.uid()::text||'/forged/source.jpg');
    raise exception 'Client storage insert unexpectedly permitted';
  exception when insufficient_privilege then null; end;
end $$;

select set_config('request.jwt.claim.sub',current_setting('test.user_b'),true);
select set_config('request.jwt.claims',json_build_object('sub',current_setting('test.user_b'),'role','authenticated')::text,true);
do $$ begin
  if exists(select 1 from public.analysis_jobs where id='11111111-1111-4111-8111-111111111111')
    then raise exception 'User B read user A job'; end if;
  if not exists(select 1 from public.analysis_jobs where id='22222222-2222-4222-8222-222222222222')
    then raise exception 'User B cannot read own job'; end if;
end $$;
reset role;
rollback;
