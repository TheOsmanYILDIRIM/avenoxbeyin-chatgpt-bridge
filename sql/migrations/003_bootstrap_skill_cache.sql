-- Bootstrap + skill cache only. No source-file or context cache.

create table if not exists private.avenox_bootstrap_cache (
  singleton boolean primary key default true check (singleton),
  cache_hash text not null,
  brain_version text,
  response_text text not null,
  skills_manifest jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists private.avenox_bootstrap_history (
  cache_hash text primary key,
  brain_version text,
  response_text text not null,
  skills_manifest jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists private.avenox_skill_cache (
  name text primary key,
  cache_hash text not null,
  description text,
  response_text text not null,
  updated_at timestamptz not null default now()
);

create or replace function public.publish_avenox_cache(
  p_brain_version text,
  p_bootstrap_hash text,
  p_bootstrap_text text,
  p_skills_manifest jsonb,
  p_skills jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_skill jsonb;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id = v_uid and w.enabled
  ) then
    raise exception 'unauthorized worker';
  end if;

  insert into private.avenox_bootstrap_history(
    cache_hash,brain_version,response_text,skills_manifest
  )
  values(
    p_bootstrap_hash,p_brain_version,p_bootstrap_text,
    coalesce(p_skills_manifest,'[]'::jsonb)
  )
  on conflict(cache_hash) do nothing;

  insert into private.avenox_bootstrap_cache(
    singleton,cache_hash,brain_version,response_text,skills_manifest,updated_at
  )
  values(
    true,p_bootstrap_hash,p_brain_version,p_bootstrap_text,
    coalesce(p_skills_manifest,'[]'::jsonb),now()
  )
  on conflict(singleton) do update
  set cache_hash=excluded.cache_hash,
      brain_version=excluded.brain_version,
      response_text=excluded.response_text,
      skills_manifest=excluded.skills_manifest,
      updated_at=now();

  for v_skill in
    select value from jsonb_array_elements(coalesce(p_skills,'[]'::jsonb))
  loop
    insert into private.avenox_skill_cache(
      name,cache_hash,description,response_text,updated_at
    )
    values(
      v_skill->>'name',
      v_skill->>'sha256',
      v_skill->>'description',
      v_skill->>'content',
      now()
    )
    on conflict(name) do update
    set cache_hash=excluded.cache_hash,
        description=excluded.description,
        response_text=excluded.response_text,
        updated_at=now();
  end loop;

  return jsonb_build_object(
    'status','published',
    'bootstrap_hash',p_bootstrap_hash,
    'skills_updated',jsonb_array_length(coalesce(p_skills,'[]'::jsonb))
  );
end;
$$;

revoke all on function public.publish_avenox_cache(text,text,text,jsonb,jsonb)
  from public,anon;
grant execute on function public.publish_avenox_cache(text,text,text,jsonb,jsonb)
  to authenticated;

create or replace function public.avenox_cached_bootstrap(p_known_hash text default null)
returns jsonb
language sql
security invoker
set search_path=''
as $$
  with cur as (
    select * from private.avenox_bootstrap_cache where singleton=true
  ),
  old as (
    select skills_manifest
    from private.avenox_bootstrap_history
    where cache_hash=p_known_hash
  ),
  changed as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'name',c.item->>'name',
      'sha256',c.item->>'sha256',
      'description',c.item->>'description'
    ) order by c.item->>'name'),'[]'::jsonb) as items
    from cur
    cross join lateral jsonb_array_elements(cur.skills_manifest) c(item)
    left join old on true
    left join lateral (
      select o.item
      from jsonb_array_elements(coalesce(old.skills_manifest,'[]'::jsonb)) o(item)
      where o.item->>'name'=c.item->>'name'
      limit 1
    ) prev on true
    where p_known_hash is null
       or old.skills_manifest is null
       or prev.item is null
       or prev.item->>'sha256' is distinct from c.item->>'sha256'
  )
  select case
    when cur.cache_hash = p_known_hash then
      jsonb_build_object(
        'status','not_modified',
        'cache_hash',cur.cache_hash,
        'brain_version',cur.brain_version,
        'updated_at',cur.updated_at
      )
    else
      jsonb_build_object(
        'status','changed',
        'cache_hash',cur.cache_hash,
        'brain_version',cur.brain_version,
        'response_text',cur.response_text,
        'skills_manifest',cur.skills_manifest,
        'changed_skills',(select items from changed),
        'updated_at',cur.updated_at
      )
  end
  from cur;
$$;

create or replace function public.avenox_cached_skill(
  p_name text,
  p_known_hash text default null
)
returns jsonb
language sql
security invoker
set search_path=''
as $$
  with current_manifest as (
    select x.item->>'sha256' as current_hash
    from private.avenox_bootstrap_cache b
    cross join lateral jsonb_array_elements(b.skills_manifest) x(item)
    where b.singleton=true and x.item->>'name'=p_name
    limit 1
  ),
  cached as (
    select * from private.avenox_skill_cache where name=p_name
  )
  select case
    when m.current_hash is null then
      jsonb_build_object('status','not_found','name',p_name)
    when c.cache_hash is null or c.cache_hash <> m.current_hash then
      jsonb_build_object('status','stale','name',p_name,'current_hash',m.current_hash)
    when c.cache_hash = p_known_hash then
      jsonb_build_object(
        'status','not_modified',
        'name',c.name,
        'cache_hash',c.cache_hash,
        'updated_at',c.updated_at
      )
    else
      jsonb_build_object(
        'status','changed',
        'name',c.name,
        'cache_hash',c.cache_hash,
        'description',c.description,
        'response_text',c.response_text,
        'updated_at',c.updated_at
      )
  end
  from current_manifest m
  left join cached c on true;
$$;

revoke all on function public.avenox_cached_bootstrap(text)
  from public,anon,authenticated;
revoke all on function public.avenox_cached_skill(text,text)
  from public,anon,authenticated;
