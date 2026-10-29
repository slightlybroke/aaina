-- Local PostgreSQL-only harness, transaction rolled back. Requires auth/roles stubs.
\set ON_ERROR_STOP on
begin;
create schema if not exists storage;
create table if not exists storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
\ir ../migrations/202610280001_makeup_vto.sql
insert into auth.users(id) values('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222') on conflict do nothing;
insert into public.vto_jobs(id,user_id,idempotency_key,image_sha256,options,consent_version,source_path,result_path,expires_at,status)
select id,u,id,'hash','{}','makeup-vto-v1',u::text||'/'||id::text||'/source.jpg',u::text||'/'||id::text||'/preview.jpg',now()+interval '1 hour','pending'
from (values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'11111111-1111-4111-8111-111111111111'::uuid),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,'22222222-2222-4222-8222-222222222222'::uuid)) x(id,u);
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
do $$begin
 if (select count(*) from public.vto_jobs)<>1 then raise exception 'RLS owner A failed'; end if;
 if exists(select 1 from public.vto_jobs where user_id='22222222-2222-4222-8222-222222222222') then raise exception 'cross-owner read'; end if;
 if has_table_privilege('authenticated','public.vto_jobs','INSERT,UPDATE,DELETE') then raise exception 'client write grant'; end if;
 if has_function_privilege('authenticated','public.claim_vto_job(uuid)','EXECUTE') then raise exception 'client worker access'; end if;
end$$;
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$begin if (select count(*) from public.vto_jobs)<>1 then raise exception 'RLS owner B failed'; end if; end$$;
reset role;
select * from public.claim_vto_job('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
do $$begin
 if public.complete_vto_job('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','cccccccc-cccc-4ccc-8ccc-cccccccccccc') then raise exception 'completed pending job'; end if;
 if (select count(*) from public.vto_jobs where lease_token is not null)<>1 then raise exception 'lease claim failed'; end if;
 if (select public from storage.buckets where id='vto-images') then raise exception 'public bucket'; end if;
end$$;
update public.vto_jobs set status='processing' where lease_token is not null;
do $$declare j uuid;begin
 select id into j from public.vto_jobs where lease_token is not null;
 if public.complete_vto_job(j,'dddddddd-dddd-4ddd-8ddd-dddddddddddd') then raise exception 'wrong lease completed'; end if;
 if not public.complete_vto_job(j,'cccccccc-cccc-4ccc-8ccc-cccccccccccc') then raise exception 'completion failed'; end if;
 if public.complete_vto_job(j,'cccccccc-cccc-4ccc-8ccc-cccccccccccc') then raise exception 'duplicate completion'; end if;
end$$;
rollback;
