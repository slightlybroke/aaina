-- Supplemental claims-based SQL checks; no live Auth login proof. All fixtures roll back.
begin;
create temporary table vanity_fixture(a uuid,b uuid,item uuid,body jsonb);
insert into vanity_fixture select (select id from auth.users order by id limit 1),
  (select id from auth.users order by id offset 1 limit 1),gen_random_uuid(),
  '{"name":"Literal 50%_ shade","brand":"","category":"lipstick","shade_name":"","shade_identifier":"","finish":"","undertone":"","notes":""}'::jsonb;
do $$ declare f record; first jsonb; result jsonb; changed jsonb; begin
  select * into f from vanity_fixture;
  if f.a is null or f.b is null then raise exception 'Two test Auth users required'; end if;
  first := public.save_vanity_item(f.a,f.item,f.body,null);
  result := public.save_vanity_item(f.a,f.item,f.body,null);
  if first->>'id' is null or result->>'version'<>'1' then raise exception 'Create retry failed'; end if;
  changed := f.body||'{"shade_name":"Known shade","notes":"Edited"}'::jsonb;
  result := public.save_vanity_item(f.a,f.item,changed,1);
  if result->>'version'<>'2' or result->>'shade_name'<>'Known shade' then raise exception 'Update failed'; end if;
  result := public.save_vanity_item(f.a,f.item,changed,1);
  if result->>'version'<>'2' then raise exception 'Update retry not idempotent'; end if;
  result := public.save_vanity_item(f.a,f.item,f.body,1);
  if result->>'status'<>'409' then raise exception 'Stale overwrite allowed'; end if;
  result := public.save_vanity_item(f.b,f.item,f.body,null);
  if result->>'status'<>'404' then raise exception 'Other owner overwrite allowed'; end if;
  result := public.list_vanity_items(f.a,'50%_','lipstick',0);
  if jsonb_array_length(result->'items')<>1 then raise exception 'Literal search/filter failed'; end if;
  result := public.list_vanity_items(f.a,'does not exist','',0);
  if jsonb_array_length(result->'items')<>0 then raise exception 'Search ignored'; end if;
  result := public.list_vanity_items(f.b,'50%_','',0);
  if jsonb_array_length(result->'items')<>0 then raise exception 'Cross-user listing allowed'; end if;
end $$;
grant select on vanity_fixture to authenticated;
select set_config('request.jwt.claim.sub',(select a::text from vanity_fixture),true);
select set_config('request.jwt.claims',json_build_object('sub',(select a from vanity_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if not exists(select 1 from public.vanity_items where id=(select item from vanity_fixture)) then raise exception 'Own read denied'; end if;
  begin
    update public.vanity_items set notes='Forbidden' where id=(select item from vanity_fixture);
    raise exception 'Client write allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.list_vanity_items((select b from vanity_fixture),'','',0);
    raise exception 'Client privileged RPC allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select b::text from vanity_fixture),true);
select set_config('request.jwt.claims',json_build_object('sub',(select b from vanity_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.vanity_items where id=(select item from vanity_fixture)) then raise exception 'Cross-user RLS failed'; end if;
  begin
    delete from public.vanity_items where id=(select item from vanity_fixture);
    raise exception 'Client delete allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
