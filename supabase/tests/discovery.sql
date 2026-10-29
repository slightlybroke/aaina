\set ON_ERROR_STOP on
begin;
\ir ../migrations/202610280002_product_discovery.sql
insert into public.discovery_products(id,name,brand,category,source_url,source_region,checked_on,active)
values('11111111-1111-4111-8111-111111111111','Fixture mascara','Fixture brand','mascara','https://www.maybelline.com/','US',current_date,true),
 ('22222222-2222-4222-8222-222222222222','Inactive mascara','Fixture brand','mascara','https://www.maybelline.com/','US',current_date,false);
set local role authenticated;
do $$begin
 if (select count(*) from public.discovery_products)<>1 then raise exception 'active RLS failed';end if;
 if has_table_privilege('authenticated','public.discovery_products','INSERT,UPDATE,DELETE') then raise exception 'catalogue write allowed';end if;
 if has_function_privilege('anon','public.search_discovery(text,text,text,integer)','EXECUTE') then raise exception 'anonymous RPC allowed';end if;
end$$;
reset role;
do $$declare result jsonb;begin
 result:=public.search_discovery('mascara','mascara','Fixture brand',0);
 if jsonb_array_length(result->'items')<>1 then raise exception 'search failed';end if;
 result:=public.search_discovery('doesnotexist','','',0);
 if jsonb_array_length(result->'items')<>0 then raise exception 'empty search failed';end if;
end$$;
insert into public.discovery_products(id,name,brand,category,source_url,source_region,checked_on)
select gen_random_uuid(),'Fixture '||i,'Fixture brand','lipstick','https://www.maybelline.com/','US',current_date from generate_series(1,25)i;
do $$declare result jsonb;begin
 result:=public.search_discovery('fixture','lipstick','',0);
 if jsonb_array_length(result->'items')<>20 or not (result->>'has_more')::boolean then raise exception 'page one failed';end if;
 result:=public.search_discovery('fixture','lipstick','',20);
 if jsonb_array_length(result->'items')<>5 or (result->>'has_more')::boolean then raise exception 'page two failed';end if;
end$$;
rollback;
