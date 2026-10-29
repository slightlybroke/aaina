\set ON_ERROR_STOP on
begin;
\ir ../migrations/202610280003_makeup_preferences.sql
insert into auth.users(id) values('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222') on conflict do nothing;
insert into public.makeup_preferences(user_id,preferred_finish) values
 ('11111111-1111-4111-8111-111111111111','satin'),('22222222-2222-4222-8222-222222222222','matte');
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
do $$begin
 if (select count(*) from public.makeup_preferences)<>1 then raise exception 'owner isolation failed';end if;
 if (select preferred_finish from public.makeup_preferences)<>'satin' then raise exception 'foreign profile';end if;
 if has_table_privilege('authenticated','public.makeup_preferences','INSERT,UPDATE,DELETE') then raise exception 'direct mutation permitted';end if;
 if has_table_privilege('anon','public.makeup_preferences','SELECT') then raise exception 'anonymous read permitted';end if;
end$$;
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$begin if (select preferred_finish from public.makeup_preferences)<>'matte' then raise exception 'owner B failed';end if;end$$;
reset role;
rollback;
