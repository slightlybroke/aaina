\set ON_ERROR_STOP on
begin;
\ir ../migrations/202610280005_weekly_reports.sql
insert into auth.users(id) values('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222') on conflict do nothing;
insert into public.weekly_reports(user_id,week_start,week_end,timezone,content) values
 ('11111111-1111-4111-8111-111111111111','2026-10-19','2026-10-25','UTC','{}'),
 ('22222222-2222-4222-8222-222222222222','2026-10-19','2026-10-25','UTC','{}');
insert into public.weekly_reports(user_id,week_start,week_end,timezone,content) values
 ('11111111-1111-4111-8111-111111111111','2026-10-19','2026-10-25','UTC','{}') on conflict(user_id,week_start) do nothing;
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
do $$begin
 if (select count(*) from public.weekly_reports)<>1 then raise exception 'Owner RLS/idempotency failed';end if;
 if has_table_privilege('authenticated','public.weekly_reports','INSERT,UPDATE,DELETE') then raise exception 'Direct writes permitted';end if;
 if has_table_privilege('anon','public.weekly_reports','SELECT') then raise exception 'Anonymous read permitted';end if;
end$$;
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$begin if (select count(*) from public.weekly_reports)<>1 then raise exception 'Owner B RLS failed';end if;end$$;
reset role;
rollback;
