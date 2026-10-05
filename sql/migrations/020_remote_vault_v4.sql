-- 020_remote_vault_v4.sql
-- Remote-first Brain vault. Supabase keeps a versioned, content-addressed HEAD;
-- Termux is an optional replica/worker and exchanges only changed content after seed.

begin;

create table if not exists private.brain_vault_blobs (
  sha256 text primary key check (length(sha256)=64),
  content text not null,
  size_bytes bigint generated always as (octet_length(content)) stored,
  created_at timestamptz not null default now()
);

create index if not exists brain_vault_blobs_fts_idx
  on private.brain_vault_blobs using gin (to_tsvector('simple'::regconfig,content));

create table if not exists private.brain_vault_commits (
  commit_seq bigint generated always as identity primary key,
  commit_id uuid not null unique default extensions.gen_random_uuid(),
  parent_seq bigint,
  actor text not null,
  kind text not null check (kind in ('seed','remote_write','replica_push','merge')),
  summary text,
  created_at timestamptz not null default now()
);

create table if not exists private.brain_vault_heads (
  source text primary key,
  sha256 text not null references private.brain_vault_blobs(sha256),
  revision bigint not null default 1 check (revision>0),
  commit_seq bigint not null references private.brain_vault_commits(commit_seq),
  updated_at timestamptz not null default now()
);

create table if not exists private.brain_vault_changes (
  commit_seq bigint not null references private.brain_vault_commits(commit_seq) on delete cascade,
  source text not null,
  old_sha256 text,
  new_sha256 text,
  operation text not null check (operation in ('add','modify','delete')),
  primary key(commit_seq,source)
);
create index if not exists brain_vault_changes_source_idx
  on private.brain_vault_changes(source,commit_seq desc);

create table if not exists private.brain_vault_replica_state (
  replica_uid uuid primary key,
  cursor_commit_seq bigint not null default 0,
  tree_hash text,
  last_sync_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists private.brain_vault_replica_paths (
  replica_uid uuid not null,
  source text not null,
  base_sha256 text,
  seen_commit_seq bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key(replica_uid,source)
);

create table if not exists private.brain_vault_conflicts (
  id uuid primary key default extensions.gen_random_uuid(),
  replica_uid uuid not null default '00000000-0000-0000-0000-000000000000'::uuid,
  source text not null,
  base_sha256 text,
  local_sha256 text,
  remote_sha256 text,
  status text not null default 'open' check (status in ('open','resolved')),
  resolved_sha256 text,
  resolved_commit_seq bigint,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index if not exists brain_vault_conflicts_open_path_idx
  on private.brain_vault_conflicts(replica_uid,source) where status='open';

revoke all on private.brain_vault_blobs from public,anon,authenticated;
revoke all on private.brain_vault_commits from public,anon,authenticated;
revoke all on private.brain_vault_heads from public,anon,authenticated;
revoke all on private.brain_vault_changes from public,anon,authenticated;
revoke all on private.brain_vault_replica_state from public,anon,authenticated;
revoke all on private.brain_vault_replica_paths from public,anon,authenticated;
revoke all on private.brain_vault_conflicts from public,anon,authenticated;

create or replace function private.brain_remote_assert_actor(p_worker_only boolean default false)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_role text := coalesce(auth.jwt()->>'role','');
begin
  if not p_worker_only and v_role='service_role' then return v_uid; end if;
  if v_uid is not null and exists(
    select 1 from private.bridge_workers w where w.user_id=v_uid and w.enabled
  ) then return v_uid; end if;
  raise exception 'unauthorized Brain remote-vault actor';
end;
$$;
revoke all on function private.brain_remote_assert_actor(boolean) from public,anon,authenticated;

create or replace function private.brain_remote_source(p_source text,p_direct_write boolean default false)
returns text
language plpgsql
security invoker
immutable
set search_path=''
as $$
declare
  v text;
  parts text[];
  base text;
  ext text;
  allowed_read text[] := array[
    '.md','.txt','.json','.yaml','.yml','.toml','.csv','.tsv',
    '.py','.js','.mjs','.cjs','.ts','.tsx','.jsx','.html','.css','.sql','.sh','.ps1','.ini','.cfg'
  ];
  allowed_write text[] := array['.md','.txt','.json','.yaml','.yml','.toml','.csv','.tsv'];
begin
  if p_source is null or btrim(p_source)='' or position(chr(0) in p_source)>0 then
    raise exception 'invalid vault source';
  end if;
  v := regexp_replace(replace(btrim(p_source),chr(92),'/'),'/+','/','g');
  if left(v,1)='/' or v ~ '(^|/)[.][.](/|$)' then raise exception 'invalid vault source'; end if;
  parts := regexp_split_to_array(v,'/');
  if exists(select 1 from unnest(parts) p where lower(p) in
    ('.git','node_modules','__pycache__','.venv','venv')) then
    raise exception 'vault source is not remotely mirrorable';
  end if;
  base := lower(parts[array_length(parts,1)]);
  if base in ('.env','.env.local','.env.production','.npmrc','.netrc','config.local.json',
      'credentials','credentials.json','service-account.json','id_rsa','id_ed25519')
     or base like 'id_rsa%' or base like 'id_ed25519%' then
    raise exception 'vault source is not remotely mirrorable';
  end if;
  ext := lower(coalesce(substring(base from '([.][^.]+)$'),''));
  if ext in ('.pem','.key','.p12','.pfx','.sqlite','.sqlite3','.db')
     or not (ext=any(allowed_read)) then
    raise exception 'vault source extension is not remotely mirrorable';
  end if;
  if p_direct_write then
    if exists(select 1 from unnest(parts) p where left(p,1)='.')
       or not (ext=any(allowed_write)) then
      raise exception 'vault source is read-only remotely';
    end if;
  end if;
  return v;
end;
$$;
revoke all on function private.brain_remote_source(text,boolean) from public,anon,authenticated;

create or replace function private.brain_remote_task_source(p_source text,p_content text)
returns boolean
language sql
security invoker
immutable
set search_path=''
as $$
  select p_source ~* '(^|/)tasks/'
    or left(coalesce(p_content,''),4096) ~* 'kind[[:space:]]*:[[:space:]]*[''"]?task'
    or left(coalesce(p_content,''),4096) ~* '"kind"[[:space:]]*:[[:space:]]*"task"';
$$;
revoke all on function private.brain_remote_task_source(text,text) from public,anon,authenticated;

create or replace function private.brain_remote_context_allowed(p_content text)
returns boolean
language plpgsql
security invoker
immutable
set search_path=''
as $$
declare h text := left(coalesce(p_content,''),4096);
begin
  if h ~* 'visibility[[:space:]]*:[[:space:]]*[''"]?private'
     or h ~* '"visibility"[[:space:]]*:[[:space:]]*"private"'
     or h ~* 'remote_allowed[[:space:]]*:[[:space:]]*false'
     or h ~* '"remote_allowed"[[:space:]]*:[[:space:]]*false'
     or h ~* 'sensitivity[[:space:]]*:[[:space:]]*[''"]?(secret|sensitive|restricted)'
  then return false; end if;
  return true;
end;
$$;
revoke all on function private.brain_remote_context_allowed(text) from public,anon,authenticated;

create or replace function private.brain_remote_sha(p_content text)
returns text
language sql
security invoker
immutable
set search_path=''
as $$
  select pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(coalesce(p_content,''),'UTF8'),'sha256'),'hex'
  );
$$;
revoke all on function private.brain_remote_sha(text) from public,anon,authenticated;

create or replace function private.brain_remote_put_blob(p_content text)
returns text
language plpgsql
security invoker
set search_path=''
as $$
declare s text := private.brain_remote_sha(p_content);
begin
  if octet_length(coalesce(p_content,''))>2097152 then raise exception 'vault source too large'; end if;
  insert into private.brain_vault_blobs(sha256,content)
  values(s,coalesce(p_content,'')) on conflict(sha256) do nothing;
  return s;
end;
$$;
revoke all on function private.brain_remote_put_blob(text) from public,anon,authenticated;

create or replace function private.brain_remote_commit(
  p_source text,p_sha text,p_actor text,p_kind text,p_summary text default null
) returns bigint
language plpgsql
security invoker
set search_path=''
as $$
declare old_sha text; old_rev bigint; parent bigint; seq bigint;
begin
  perform pg_catalog.pg_advisory_xact_lock(734968211);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_source,0));
  select h.sha256,h.revision into old_sha,old_rev
  from private.brain_vault_heads h where h.source=p_source for update;
  if old_sha=p_sha then
    select commit_seq into seq from private.brain_vault_heads where source=p_source;
    return seq;
  end if;
  select max(commit_seq) into parent from private.brain_vault_commits;
  insert into private.brain_vault_commits(parent_seq,actor,kind,summary)
  values(parent,left(coalesce(nullif(p_actor,''),'unknown'),200),p_kind,left(p_summary,1000))
  returning commit_seq into seq;
  insert into private.brain_vault_heads(source,sha256,revision,commit_seq,updated_at)
  values(p_source,p_sha,1,seq,now())
  on conflict(source) do update set
    sha256=excluded.sha256,revision=private.brain_vault_heads.revision+1,
    commit_seq=excluded.commit_seq,updated_at=now();
  insert into private.brain_vault_changes(commit_seq,source,old_sha256,new_sha256,operation)
  values(seq,p_source,old_sha,p_sha,case when old_sha is null then 'add' else 'modify' end);
  return seq;
end;
$$;
revoke all on function private.brain_remote_commit(text,text,text,text,text) from public,anon,authenticated;

create or replace function private.brain_remote_tree_hash()
returns text
language sql
security invoker
stable
set search_path=''
as $$
  select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
    coalesce(string_agg(source||':'||sha256,E'\n' order by source),''),'UTF8'),'sha256'),'hex')
  from private.brain_vault_heads;
$$;
revoke all on function private.brain_remote_tree_hash() from public,anon,authenticated;

create or replace function private.brain_remote_status()
returns jsonb
language sql
security invoker
stable
set search_path=''
as $$
  select jsonb_build_object(
    'version',1,
    'seeded',exists(select 1 from private.brain_vault_heads),
    'head_commit_seq',coalesce((select max(commit_seq) from private.brain_vault_commits),0),
    'tree_hash',private.brain_remote_tree_hash(),
    'file_count',(select count(*) from private.brain_vault_heads),
    'open_conflicts',(select count(*) from private.brain_vault_conflicts where status='open')
  );
$$;
revoke all on function private.brain_remote_status() from public,anon,authenticated;

create or replace function public.brain_remote_rpc(p_operation text,p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  op text := lower(coalesce(p_operation,''));
  src text; q text; path text; cur text; fresh text; content text; actor text;
  seq bigint; lim integer; start_line integer; end_line integer;
  out jsonb; arr jsonb; lines text[]; uid uuid;
begin
  uid := private.brain_remote_assert_actor(false);

  if op='head' then return private.brain_remote_status(); end if;

  if op='list' then
    path := trim(both '/' from coalesce(p->>'path',''));
    lim := least(greatest(coalesce((p->>'max_entries')::integer,500),1),5000);
    select coalesce(jsonb_agg(x order by x->>'source'),'[]'::jsonb) into arr
    from (
      select jsonb_build_object(
        'source',h.source,'sha256',h.sha256,'size_bytes',b.size_bytes,
        'revision',h.revision,'commit_seq',h.commit_seq,'updated_at',h.updated_at
      ) x
      from private.brain_vault_heads h join private.brain_vault_blobs b on b.sha256=h.sha256
      where path='' or h.source=path or h.source like path||'/%'
      order by h.source limit lim
    ) s;
    return jsonb_build_object('entries',arr,'head',private.brain_remote_status());
  end if;

  if op='find' then
    q := nullif(p->>'query',''); if q is null then raise exception 'query is required'; end if;
    path := trim(both '/' from coalesce(p->>'path',''));
    lim := least(greatest(coalesce((p->>'max_results')::integer,100),1),500);
    select coalesce(jsonb_agg(x order by x->>'source'),'[]'::jsonb) into arr
    from (
      select jsonb_build_object('source',h.source,'sha256',h.sha256,'size_bytes',b.size_bytes) x
      from private.brain_vault_heads h join private.brain_vault_blobs b on b.sha256=h.sha256
      where h.source ilike ('%'||q||'%') and (path='' or h.source=path or h.source like path||'/%')
      order by h.source limit lim
    ) s;
    return jsonb_build_object('query',q,'matches',arr);
  end if;

  if op='get' then
    src := private.brain_remote_source(p->>'source',false);
    select jsonb_build_object(
      'found',true,'source',h.source,'sha256',h.sha256,'size_bytes',b.size_bytes,
      'revision',h.revision,'commit_seq',h.commit_seq,'updated_at',h.updated_at,'content',b.content
    ) into out
    from private.brain_vault_heads h join private.brain_vault_blobs b on b.sha256=h.sha256
    where h.source=src;
    if out is null then return jsonb_build_object('found',false,'source',src); end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'base_sha256',c.base_sha256,'local_sha256',c.local_sha256,
      'remote_sha256',c.remote_sha256,'base_content',bb.content,
      'local_content',lb.content,'remote_content',rb.content,'created_at',c.created_at
    ) order by c.created_at),'[]'::jsonb) into arr
    from private.brain_vault_conflicts c
    left join private.brain_vault_blobs bb on bb.sha256=c.base_sha256
    left join private.brain_vault_blobs lb on lb.sha256=c.local_sha256
    left join private.brain_vault_blobs rb on rb.sha256=c.remote_sha256
    where c.status='open' and c.source=src;
    return out||jsonb_build_object('conflicts',arr);
  end if;

  if op='read_range' then
    src := private.brain_remote_source(p->>'source',false);
    start_line := (p->>'start_line')::integer; end_line := (p->>'end_line')::integer;
    if start_line<1 or end_line<start_line or end_line-start_line+1>500 then raise exception 'invalid line range'; end if;
    select h.sha256,b.content into cur,content
    from private.brain_vault_heads h join private.brain_vault_blobs b on b.sha256=h.sha256
    where h.source=src;
    if cur is null then raise exception 'vault source not found'; end if;
    lines := string_to_array(replace(content,E'\r\n',E'\n'),E'\n');
    end_line := least(end_line,coalesce(array_length(lines,1),0));
    return jsonb_build_object(
      'source',src,'sha256',cur,'total_lines',coalesce(array_length(lines,1),0),
      'start_line',start_line,'end_line',end_line,
      'content',case when start_line>coalesce(array_length(lines,1),0) then ''
        else array_to_string(lines[start_line:end_line],E'\n') end
    );
  end if;

  if op='search' then
    q := nullif(p->>'query',''); if q is null then raise exception 'query is required'; end if;
    path := trim(both '/' from coalesce(p->>'path',''));
    lim := least(greatest(coalesce((p->>'max_results')::integer,100),1),500);
    select coalesce(jsonb_agg(jsonb_build_object(
      'source',z.source,'sha256',z.sha256,'line',z.n,
      'column',position(lower(q) in lower(z.line)),
      'excerpt',case when length(z.line)<=400 then z.line else left(z.line,400)||'…' end
    ) order by z.source,z.n),'[]'::jsonb) into arr
    from (
      select h.source,h.sha256,l.line,l.n
      from private.brain_vault_heads h
      join private.brain_vault_blobs b on b.sha256=h.sha256
      cross join lateral unnest(string_to_array(replace(b.content,E'\r\n',E'\n'),E'\n'))
        with ordinality as l(line,n)
      where (path='' or h.source=path or h.source like path||'/%')
        and position(lower(q) in lower(l.line))>0
      order by h.source,l.n limit lim
    ) z;
    return jsonb_build_object('query',q,'matches',arr);
  end if;

  if op='context' then
    q := nullif(p->>'query',''); if q is null then raise exception 'query is required'; end if;
    lim := least(greatest(coalesce((p->>'limit')::integer,8),1),50);
    select coalesce(jsonb_agg(jsonb_build_object(
      'source',z.source,'sha256',z.sha256,'commit_seq',z.commit_seq,
      'score',z.score,'text',left(z.content,4000)
    ) order by z.score desc,z.commit_seq desc),'[]'::jsonb) into arr
    from (
      select h.source,h.sha256,h.commit_seq,b.content,
        ts_rank_cd(to_tsvector('simple'::regconfig,b.content),plainto_tsquery('simple'::regconfig,q)) score
      from private.brain_vault_heads h join private.brain_vault_blobs b on b.sha256=h.sha256
      where private.brain_remote_context_allowed(b.content)
        and (
          to_tsvector('simple'::regconfig,b.content)@@plainto_tsquery('simple'::regconfig,q)
          or b.content ilike ('%'||q||'%') or h.source ilike ('%'||q||'%')
        )
        and (coalesce(p->>'project','')='' or h.source ilike ('%'||(p->>'project')||'%')
             or b.content ilike ('%'||(p->>'project')||'%'))
      order by score desc,h.commit_seq desc limit lim
    ) z;
    return jsonb_build_object('query',q,'records',arr,'head',private.brain_remote_status());
  end if;

  if op='conflicts' then
    lim := least(greatest(coalesce((p->>'limit')::integer,50),1),200);
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'source',c.source,'base_sha256',c.base_sha256,'local_sha256',c.local_sha256,
      'remote_sha256',c.remote_sha256,'base_content',bb.content,'local_content',lb.content,
      'remote_content',rb.content,'created_at',c.created_at
    ) order by c.created_at),'[]'::jsonb) into arr
    from (
      select * from private.brain_vault_conflicts where status='open'
      order by created_at limit lim
    ) c
    left join private.brain_vault_blobs bb on bb.sha256=c.base_sha256
    left join private.brain_vault_blobs lb on lb.sha256=c.local_sha256
    left join private.brain_vault_blobs rb on rb.sha256=c.remote_sha256;
    return jsonb_build_object('open_conflicts',arr,'head',private.brain_remote_status());
  end if;

  if op='update' then
    src := private.brain_remote_source(p->>'source',true);
    cur := p->>'expected_sha256'; content := coalesce(p->>'content',''); actor := coalesce(p->>'actor','chatgpt');
    if cur is null or length(cur)<>64 then raise exception 'expected_sha256 must be SHA-256'; end if;
    if private.brain_remote_task_source(src,content) then raise exception 'task sources must use brain_task_update'; end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(src,0));
    select sha256 into fresh from private.brain_vault_heads where source=src for update;
    if fresh is null then raise exception 'vault source not found'; end if;
    content := coalesce(content,''); q := private.brain_remote_put_blob(content);
    if fresh<>cur then
      insert into private.brain_vault_conflicts(replica_uid,source,base_sha256,local_sha256,remote_sha256)
      values(coalesce(uid,'00000000-0000-0000-0000-000000000000'::uuid),src,cur,q,fresh)
      on conflict(replica_uid,source) where status='open' do update set
        base_sha256=excluded.base_sha256,local_sha256=excluded.local_sha256,
        remote_sha256=excluded.remote_sha256,created_at=now();
      return jsonb_build_object('status','conflict','source',src,'base_sha256',cur,
        'submitted_sha256',q,'remote_sha256',fresh,'preserved',true);
    end if;
    seq := private.brain_remote_commit(src,q,actor,'remote_write','remote CAS update');
    update private.brain_vault_conflicts set status='resolved',resolved_sha256=q,
      resolved_commit_seq=seq,resolved_at=now() where source=src and status='open';
    return jsonb_build_object('status',case when q=fresh then 'unchanged' else 'completed' end,
      'source',src,'previous_sha256',fresh,'sha256',q,'commit_seq',seq,'head',private.brain_remote_status());
  end if;

  raise exception 'unsupported Brain remote operation';
end;
$$;

revoke all on function public.brain_remote_rpc(text,jsonb) from public,anon,authenticated;
grant execute on function public.brain_remote_rpc(text,jsonb) to authenticated,service_role;

create or replace function public.brain_remote_replica_rpc(p_operation text,p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  op text := lower(coalesce(p_operation,'')); uid uuid;
  src text; base text; local_sha text; remote_sha text; content text; remote_content text;
  seq bigint; lim integer; cursor_seq bigint; e jsonb; arr jsonb; acked integer:=0;
begin
  uid := private.brain_remote_assert_actor(true);

  if op='state' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'source',x.source,'base_sha256',x.base_sha256,'seen_commit_seq',x.seen_commit_seq
    ) order by x.source),'[]'::jsonb) into arr
    from private.brain_vault_replica_paths x where x.replica_uid=uid;
    return jsonb_build_object(
      'paths',arr,
      'cursor_commit_seq',coalesce((select cursor_commit_seq from private.brain_vault_replica_state where replica_uid=uid),0),
      'tree_hash',(select tree_hash from private.brain_vault_replica_state where replica_uid=uid),
      'remote',private.brain_remote_status()
    );
  end if;

  if op='changes' then
    cursor_seq := coalesce((p->>'since')::bigint,0);
    lim := least(greatest(coalesce((p->>'limit')::integer,1000),1),5000);
    select coalesce(jsonb_agg(jsonb_build_object(
      'commit_seq',z.commit_seq,'source',z.source,'old_sha256',z.old_sha256,
      'new_sha256',z.new_sha256,'operation',z.operation
    ) order by z.commit_seq,z.source),'[]'::jsonb) into arr
    from (
      select * from private.brain_vault_changes
      where commit_seq>cursor_seq order by commit_seq,source limit lim
    ) z;
    return jsonb_build_object('changes',arr,'remote',private.brain_remote_status());
  end if;

  if op='push' then
    src := private.brain_remote_source(p->>'source',false);
    base := nullif(p->>'base_sha256',''); content := coalesce(p->>'content','');
    local_sha := private.brain_remote_put_blob(content);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(src,0));
    select h.sha256,b.content into remote_sha,remote_content
    from private.brain_vault_heads h join private.brain_vault_blobs b on b.sha256=h.sha256
    where h.source=src for update of h;
    if remote_sha is null and base is null then
      seq := private.brain_remote_commit(src,local_sha,coalesce(p->>'actor','termux-replica'),'seed','replica seed');
      return jsonb_build_object('action','uploaded','source',src,'sha256',local_sha,'commit_seq',seq);
    end if;
    if remote_sha=local_sha then return jsonb_build_object('action','clean','source',src,'sha256',remote_sha); end if;
    if base is not null and remote_sha=base then
      seq := private.brain_remote_commit(src,local_sha,coalesce(p->>'actor','termux-replica'),'replica_push','replica local change');
      return jsonb_build_object('action','uploaded','source',src,'sha256',local_sha,'commit_seq',seq);
    end if;
    if base is not null and local_sha=base and remote_sha is not null then
      return jsonb_build_object('action','download','source',src,'sha256',remote_sha,'content',remote_content);
    end if;
    insert into private.brain_vault_conflicts(replica_uid,source,base_sha256,local_sha256,remote_sha256)
    values(uid,src,base,local_sha,remote_sha)
    on conflict(replica_uid,source) where status='open' do update set
      base_sha256=excluded.base_sha256,local_sha256=excluded.local_sha256,
      remote_sha256=excluded.remote_sha256,created_at=now();
    return jsonb_build_object('action','conflict','source',src,'base_sha256',base,
      'local_sha256',local_sha,'remote_sha256',remote_sha,'remote_content',remote_content,'preserved',true);
  end if;

  if op='ack' then
    if jsonb_typeof(p->'entries')<>'array' then raise exception 'entries must be array'; end if;
    for e in select value from jsonb_array_elements(p->'entries') loop
      src := private.brain_remote_source(e->>'source',false); local_sha := e->>'sha256';
      select sha256,commit_seq into remote_sha,seq from private.brain_vault_heads where source=src;
      if local_sha=remote_sha and not exists(
        select 1 from private.brain_vault_conflicts c
        where c.replica_uid=uid and c.source=src and c.status='open'
      ) then
        insert into private.brain_vault_replica_paths(replica_uid,source,base_sha256,seen_commit_seq,updated_at)
        values(uid,src,local_sha,coalesce(seq,0),now())
        on conflict(replica_uid,source) do update set
          base_sha256=excluded.base_sha256,seen_commit_seq=excluded.seen_commit_seq,updated_at=now();
        acked:=acked+1;
      end if;
    end loop;
    insert into private.brain_vault_replica_state(replica_uid,cursor_commit_seq,tree_hash,last_sync_at,updated_at)
    values(uid,coalesce((p->>'cursor_commit_seq')::bigint,
      (select coalesce(max(commit_seq),0) from private.brain_vault_commits)),
      coalesce(p->>'tree_hash',private.brain_remote_tree_hash()),now(),now())
    on conflict(replica_uid) do update set
      cursor_commit_seq=excluded.cursor_commit_seq,tree_hash=excluded.tree_hash,last_sync_at=now(),updated_at=now();
    return jsonb_build_object('acked',acked,'remote',private.brain_remote_status());
  end if;

  raise exception 'unsupported Brain replica operation';
end;
$$;

revoke all on function public.brain_remote_replica_rpc(text,jsonb) from public,anon,authenticated;
grant execute on function public.brain_remote_replica_rpc(text,jsonb) to authenticated;

update private.bridge_transport_meta
set schema_version=greatest(schema_version,12),updated_at=now() where singleton=true;

create or replace function public.bridge_transport_contract()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_version integer;
begin
  if not exists(select 1 from private.bridge_workers w where w.user_id=v_uid and w.enabled)
    then raise exception 'unauthorized worker'; end if;
  select schema_version into v_version from private.bridge_transport_meta where singleton=true;
  return jsonb_build_object(
    'schema_version',v_version,'claim_rpc','claim_next_brain_command_v2',
    'claim_wait_rpc','claim_next_brain_command_wait','finish_rpc','finish_brain_command_v2',
    'command_terminal_statuses',jsonb_build_array('completed','failed','conflict'),
    'vault_transport','trusted_supabase_queue',
    'remote_vault_transport','versioned_remote_vault_v1',
    'remote_vault',jsonb_build_object(
      'rpc','brain_remote_rpc','replica_rpc','brain_remote_replica_rpc',
      'direct_operations',jsonb_build_array('head','list','find','search','read_range','get','context','update'),
      'replica_operations',jsonb_build_array('state','changes','push','ack')
    )
  );
end;
$$;

create or replace function public.get_avenox_contract_snapshot()
returns jsonb
language sql
security definer
stable
set search_path=''
as $$
  select case when s.singleton then s.snapshot||jsonb_build_object(
    'published_at',s.updated_at,'remote_vault_status',private.brain_remote_status()
  ) else null end
  from public.avenox_contract_snapshot s where s.singleton=true;
$$;
revoke all on function public.get_avenox_contract_snapshot() from public,anon;
grant execute on function public.get_avenox_contract_snapshot() to authenticated,service_role;

commit;