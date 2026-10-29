create table public.beauty_memories (
 id uuid primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 category text not null check(category in ('preference','product_experience','routine_progress','event')),
 text text not null check(length(text) between 1 and 500),
 kind text not null check(kind in ('fact','inference')),
 sensitive boolean not null default false,
 status text not null check(status in ('pending','confirmed')),
 share_with_ai boolean not null default false,
 source text not null check(source in ('user_entry','user_edit','chat_literal')),
 source_quote text not null default '' check(length(source_quote)<=500),
 fingerprint text not null,
 version integer not null default 1,
 expires_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(user_id,fingerprint),
 check(category<>'event' or expires_at is not null),
 check(status='confirmed' or not share_with_ai),
 search_document tsvector generated always as(to_tsvector('simple',text)) stored
);
create index memory_owner_history on public.beauty_memories(user_id,updated_at desc,id);
create index memory_words on public.beauty_memories using gin(search_document);
alter table public.beauty_memories enable row level security;
revoke all on public.beauty_memories from anon,authenticated;
grant select on public.beauty_memories to authenticated;
grant all on public.beauty_memories to service_role;
create policy memories_read_own on public.beauty_memories for select to authenticated using((select auth.uid())=user_id);
create function public.search_beauty_memories(p_user uuid,p_query text,p_for_ai boolean,p_offset integer)
returns setof public.beauty_memories language sql stable security definer set search_path=public as $$
 select * from public.beauty_memories where user_id=p_user
 and (not p_for_ai or (status='confirmed' and share_with_ai and (expires_at is null or expires_at>now())))
 and ((not p_for_ai and p_query='') or
  search_document @@ plainto_tsquery('simple',p_query))
 order by updated_at desc,id limit (case when p_for_ai then 8 else 51 end) offset greatest(p_offset,0);
$$;
revoke all on function public.search_beauty_memories(uuid,text,boolean,integer) from public,anon,authenticated;
grant execute on function public.search_beauty_memories(uuid,text,boolean,integer) to service_role;
