-- Transactional SQL assertions: supply two dedicated Auth test users before running.
-- Run with psql -v ON_ERROR_STOP=1 or SQL editor. Never proof of live password login.
begin;
create temporary table phase2_ids as
  select id, row_number() over(order by id) as n from auth.users limit 2;
do $$ begin
  if (select count(*) from phase2_ids)<>2 then raise exception 'Two test users required'; end if;
end $$;
create temporary table phase2_fixture(a uuid,b uuid,r uuid,s uuid,rev uuid,day date);
insert into phase2_fixture select (select id from phase2_ids where n=1),
  (select id from phase2_ids where n=2),gen_random_uuid(),gen_random_uuid(),null,
  (now() at time zone 'UTC')::date;
do $$ declare f record; v jsonb; duplicate jsonb; next_revision jsonb; begin
  select * into f from phase2_fixture;
  perform public.skincare_write(f.a,'settings','{"timezone":"UTC"}');
  v := public.skincare_write(f.a,'routine', jsonb_build_object('id',f.r,'definition',
    jsonb_build_object('name','SQL acceptance','kind','morning','status','active','days',
      jsonb_build_array(extract(isodow from f.day)::int),'steps',
      jsonb_build_array(jsonb_build_object('id',f.s,'name','Cleanse')))));
  if v ? 'error' then raise exception 'Create failed: %', v; end if;
  update phase2_fixture set rev=(v->>'id')::uuid;
  f.rev := (v->>'id')::uuid;
  v := public.skincare_write(f.a,'checkin',jsonb_build_object('id',f.r,'revision_id',f.rev,
    'local_date',f.day,'completed_steps',jsonb_build_array(f.s)));
  duplicate := public.skincare_write(f.a,'checkin',jsonb_build_object('id',f.r,'revision_id',f.rev,
    'local_date',f.day,'completed_steps',jsonb_build_array(f.s)));
  if v->>'id' is null or v->>'id'<>duplicate->>'id' then raise exception 'Idempotency failed'; end if;
  v := public.skincare_write(f.a,'checkin',jsonb_build_object('id',f.r,'revision_id',f.rev,
    'local_date',f.day,'completed_steps','[]'::jsonb));
  if v->'completed_steps'<>'[]'::jsonb then raise exception 'Correction failed'; end if;
  v := public.skincare_write(f.b,'checkin',jsonb_build_object('id',f.r,'revision_id',f.rev,
    'local_date',f.day,'completed_steps','[]'::jsonb));
  if v->>'status'<>'404' then raise exception 'Cross-owner API write failed'; end if;
  v := public.skincare_write(f.a,'checkin',jsonb_build_object('id',f.r,'revision_id',f.rev,
    'local_date',f.day+1,'completed_steps','[]'::jsonb));
  if v->>'status'<>'422' then raise exception 'Future date allowed'; end if;
  next_revision := public.skincare_write(f.a,'routine',jsonb_build_object('id',f.r,
    'expected_revision',f.rev,'definition',jsonb_build_object('name','Archived','kind','custom',
      'status','archived','days','[1]'::jsonb,'steps',jsonb_build_array(jsonb_build_object('id',f.s,'name','Changed')))));
  if (next_revision->>'effective_from')::date <> f.day+1 then raise exception 'Edit backdated'; end if;
  if not exists(select 1 from public.routine_checkins where routine_id=f.r and revision_id=f.rev)
    then raise exception 'Snapshot changed'; end if;
  v := public.skincare_write(f.a,'routine',jsonb_build_object('id',f.r,'expected_revision',f.rev,
    'definition',next_revision->'definition'));
  if v->>'status'<>'409' then raise exception 'Stale edit allowed'; end if;
  v := public.skincare_write(f.a,'settings','{"timezone":"Asia/Kolkata"}');
  if v->>'status'<>'409' then raise exception 'History timezone changed'; end if;
  v := public.skincare_write(f.a,'journal',jsonb_build_object('id',f.r,'concerns','["dryness"]'::jsonb,
    'notes','Private test','severity','mild','observed_at',now()));
  if v ? 'error' then raise exception 'Journal create failed'; end if;
end $$;
grant select on phase2_fixture to authenticated;
select set_config('request.jwt.claim.sub',(select a::text from phase2_fixture),true);
select set_config('request.jwt.claims',json_build_object('sub',(select a from phase2_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if not exists(select 1 from public.routines where id=(select r from phase2_fixture)) then
    raise exception 'Own read denied'; end if;
  begin
    update public.skin_journal set notes='Forged' where id=(select r from phase2_fixture);
    raise exception 'Client update allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.skincare_write((select a from phase2_fixture),'settings','{"timezone":"UTC"}');
    raise exception 'Client RPC allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select b::text from phase2_fixture),true);
select set_config('request.jwt.claims',json_build_object('sub',(select b from phase2_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.routines where id=(select r from phase2_fixture))
    or exists(select 1 from public.routine_revisions where routine_id=(select r from phase2_fixture))
    or exists(select 1 from public.routine_checkins where routine_id=(select r from phase2_fixture))
    or exists(select 1 from public.skin_journal where id=(select r from phase2_fixture))
    or exists(select 1 from public.skincare_settings where user_id=(select a from phase2_fixture))
    then raise exception 'Cross-owner read allowed'; end if;
end $$;
reset role;
rollback;
