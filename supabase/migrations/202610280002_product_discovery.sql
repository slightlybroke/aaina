-- Public product facts, separate from private user-owned inventory.
create table public.discovery_products (
 id uuid primary key,
 name text not null check(length(name) between 1 and 150),
 brand text not null check(length(brand) between 1 and 150),
 category text not null check(length(category) between 1 and 80),
 shade_name text not null default '',
 finish text not null default '',
 source_url text not null check(source_url ~ '^https://'),
 source_region text not null,
 checked_on date not null,
 active boolean not null default true,
 search_document tsvector generated always as
   (to_tsvector('simple',name||' '||brand||' '||category||' '||shade_name||' '||finish)) stored
);
create index discovery_text on public.discovery_products using gin(search_document);
create index discovery_filters on public.discovery_products(category,brand,id) where active;
alter table public.discovery_products enable row level security;
revoke all on public.discovery_products from anon,authenticated;
grant select on public.discovery_products to authenticated;
grant all on public.discovery_products to service_role;
create policy discovery_read on public.discovery_products for select to authenticated using(active);
create function public.search_discovery(p_query text,p_category text,p_brand text,p_offset integer)
returns jsonb language sql stable security invoker set search_path=public as $$
 with matches as (
  select id,name,brand,category,shade_name,finish,source_url,source_region,checked_on
  from public.discovery_products where active
  and (p_query='' or search_document @@ plainto_tsquery('simple',p_query))
  and (p_category='' or category=p_category) and (p_brand='' or brand=p_brand)
  order by brand,name,shade_name,id limit 21 offset greatest(p_offset,0)
 ), page as (select * from matches order by brand,name,shade_name,id limit 20)
 select jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb),
  'has_more',(select count(*)>20 from matches),
  'categories',coalesce((select jsonb_agg(category order by category) from(select distinct category from public.discovery_products where active)c),'[]'::jsonb),
  'brands',coalesce((select jsonb_agg(brand order by brand) from(select distinct brand from public.discovery_products where active)b),'[]'::jsonb));
$$;
revoke all on function public.search_discovery(text,text,text,integer) from public,anon,authenticated;
grant execute on function public.search_discovery(text,text,text,integer) to service_role;
