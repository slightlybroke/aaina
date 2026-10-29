\set ON_ERROR_STOP on
begin;
\ir ../migrations/202610280004_beauty_memory.sql
insert into auth.users(id) values('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222') on conflict do nothing;
insert into public.beauty_memories(id,user_id,category,text,kind,status,share_with_ai,source,fingerprint,expires_at) values
 (gen_random_uuid(),'11111111-1111-4111-8111-111111111111','preference','matte finish','fact','confirmed',true,'user_entry','1',null),
 (gen_random_uuid(),'11111111-1111-4111-8111-111111111111','preference','private matte finish','fact','confirmed',false,'user_entry','2',null),
 (gen_random_uuid(),'11111111-1111-4111-8111-111111111111','event','expired matte finish','fact','confirmed',true,'user_entry','3',now()-interval '1 day'),
 (gen_random_uuid(),'22222222-2222-4222-8222-222222222222','preference','foreign matte finish','fact','confirmed',true,'user_entry','1',null);
do $$begin
 if (select count(*) from public.search_beauty_memories('11111111-1111-4111-8111-111111111111','finish',true,0))<>1 then raise exception 'AI filter failed';end if;
 if (select count(*) from public.search_beauty_memories('11111111-1111-4111-8111-111111111111','',true,0))<>0 then raise exception 'Unbounded AI read';end if;
end$$;
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
do $$begin
 if (select count(*) from public.beauty_memories)<>3 then raise exception 'Owner RLS failed';end if;
 if has_table_privilege('authenticated','public.beauty_memories','INSERT,UPDATE,DELETE') then raise exception 'Direct mutation permitted';end if;
 if has_table_privilege('anon','public.beauty_memories','SELECT') then raise exception 'Anonymous read permitted';end if;
 if has_function_privilege('authenticated','public.search_beauty_memories(uuid,text,boolean,integer)','EXECUTE') then raise exception 'Client RPC permitted';end if;
end$$;
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$begin if (select count(*) from public.beauty_memories)<>1 then raise exception 'Owner B RLS failed';end if;end$$;
reset role;
rollback;
