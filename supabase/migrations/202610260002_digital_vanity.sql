-- Milestone 1 only: user-owned inventory, separate from any future discovery catalogue.
begin;
create table public.vanity_items (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check(length(btrim(name)) between 1 and 150),
  brand text not null default '' check(length(brand)<=150),
  category text not null default 'other' check(length(btrim(category)) between 1 and 80),
  shade_name text not null default '' check(length(shade_name)<=120),
  shade_identifier text not null default '' check(length(shade_identifier)<=80),
  finish text not null default '' check(length(finish)<=80),
  undertone text not null default '' check(length(undertone)<=80),
  notes text not null default '' check(length(notes)<=3000),
  version integer not null default 1 check(version>0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index vanity_owner_created on public.vanity_items(user_id,created_at desc,id);
create index vanity_owner_category on public.vanity_items(user_id,category,created_at desc,id);
alter table public.vanity_items enable row level security;
revoke all on public.vanity_items from anon,authenticated;
grant select on public.vanity_items to authenticated;
grant all on public.vanity_items to service_role;
create policy vanity_read_own on public.vanity_items for select to authenticated
  using((select auth.uid())=user_id);

create function public.save_vanity_item(p_user uuid,p_id uuid,p_data jsonb,p_expected_version integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare item public.vanity_items; content jsonb;
begin
  -- Serialize same-ID creates/updates so network retries cannot insert duplicates.
  perform pg_advisory_xact_lock(hashtextextended(p_id::text,3));
  select * into item from public.vanity_items where id=p_id for update;
  if found then
    if item.user_id<>p_user then return jsonb_build_object('error','Product not found.','status',404); end if;
    content := to_jsonb(item)-array['id','user_id','version','created_at','updated_at'];
    if content=p_data then return to_jsonb(item); end if;
    if item.version is distinct from p_expected_version then
      return jsonb_build_object('error','This product changed. Reload it before editing.','status',409);
    end if;
    update public.vanity_items set name=p_data->>'name',brand=p_data->>'brand',category=p_data->>'category',
      shade_name=p_data->>'shade_name',shade_identifier=p_data->>'shade_identifier',finish=p_data->>'finish',
      undertone=p_data->>'undertone',notes=p_data->>'notes',version=version+1,updated_at=now()
      where id=p_id and user_id=p_user returning * into item;
  else
    if p_expected_version is not null then return jsonb_build_object('error','Product not found.','status',404); end if;
    insert into public.vanity_items(id,user_id,name,brand,category,shade_name,shade_identifier,finish,undertone,notes)
      values(p_id,p_user,p_data->>'name',p_data->>'brand',p_data->>'category',p_data->>'shade_name',
        p_data->>'shade_identifier',p_data->>'finish',p_data->>'undertone',p_data->>'notes') returning * into item;
  end if;
  return to_jsonb(item);
end;
$$;

-- Literal, case-insensitive substring search. Text is a bound value, never SQL/filter syntax.
create function public.list_vanity_items(p_user uuid,p_query text,p_category text,p_offset integer)
returns jsonb language sql stable security definer set search_path=public as $$
  with matches as (
    select * from public.vanity_items where user_id=p_user
      and (p_category='' or category=p_category)
      and strpos(lower(concat_ws(' ',name,brand,category,shade_name,shade_identifier,finish,undertone,notes)),lower(p_query))>0
    order by created_at desc,id limit 51 offset greatest(p_offset,0)
  ), page as (select * from matches order by created_at desc,id limit 50)
  select jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(page) order by created_at desc,id) from page),'[]'::jsonb),
    'has_more',(select count(*)>50 from matches),
    'categories',coalesce((select jsonb_agg(category order by category) from
      (select distinct category from public.vanity_items where user_id=p_user) c),'[]'::jsonb)
  );
$$;
revoke all on function public.save_vanity_item(uuid,uuid,jsonb,integer),
  public.list_vanity_items(uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.save_vanity_item(uuid,uuid,jsonb,integer),
  public.list_vanity_items(uuid,text,text,integer) to service_role;
commit;
