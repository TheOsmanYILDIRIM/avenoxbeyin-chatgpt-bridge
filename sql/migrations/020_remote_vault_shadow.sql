-- 020_remote_vault_shadow.sql
-- Git-like, content-addressed Supabase shadow for Avenox Brain.
-- Termux remains the execution/replica worker; Brain text stays readable while it is offline.

begin;

create table if not exists private.brain_remote_blobs (
  sha256 text primary key check (sha256 ~ '^[0-9a-f]{64}$'),
  content text not null,
  size_bytes integer not null check (size_bytes >= 0),
  content_tsv tsvector generated always as (to_tsvector('simple', content)) stored,
  created_at timestamptz not null default now()
);

create index if not exists brain_remote_blobs_tsv_idx
  on private.brain_remote_blobs using gin (content_tsv);

create table if not exists private.brain_remote_commits (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references private.brain_remote_commits(id),
  actor text not null,
  origin text not null,
  message text,
  created_at timestamptz not null default now()
);

create table if not exists private.brain_remote_files (
  source text primary key,
  sha256 text references private.brain_remote_blobs(sha256),
  revision bigint not null default 1 check (revision > 0),
  deleted boolean not null default false,
  updated_by text not null,
  updated_at timestamptz not null default now()
);

create table if not exists private.brain_remote_changes (
  seq bigserial primary key,
  commit_id uuid not null references private.brain_remote_commits(id) on delete cascade,
  source text not null,
  old_sha256 text,
  new_sha256 text,
  change_kind text not null check (change_kind in ('add','modify','delete')),
  created_at timestamptz not null default now()
);

create index if not exists brain_remote_changes_source_seq_idx
  on private.brain_remote_changes(source, seq desc);

create table if not exists private.brain_remote_conflicts (
  id uuid primary key default gen_random_uuid(),
  source text not null,
  base_sha256 text,
  remote_sha256 text,
  incoming_sha256 text not null references private.brain_remote_blobs(sha256),
  actor text not null,
  origin text not null,
  status text not null default 'open' check (status in ('open','resolved','dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolution_commit uuid references private.brain_remote_commits(id)
);

create index if not exists brain_remote_conflicts_open_idx
  on private.brain_remote_conflicts(status, created_at)
  where status='open';

create table if not exists private.brain_remote_replicas (
  replica_id text primary key,
  last_seq bigint not null default 0 check (last_seq >= 0),
  tree_hash text,
  last_seen_at timestamptz not null default now()
);

create table if not exists private.brain_remote_meta (
  singleton boolean primary key default true check (singleton),
  head_commit uuid references private.brain_remote_commits(id),
  head_seq bigint not null default 0 check (head_seq >= 0),
  tree_hash text not null default encode(extensions.digest(''::bytea, 'sha256'), 'hex'),
  updated_at timestamptz not null default now()
);

insert into private.brain_remote_meta(singleton)
values(true)
on conflict(singleton) do nothing;

create or replace function private.brain_remote_worker_ok()
returns boolean
language sql
security definer
stable
set search_path=''
as $$
  select exists (
    select 1
    from private.bridge_workers w
    where w.user_id=auth.uid() and w.enabled
  );
$$;

create or replace function private.brain_remote_normalize_source(p_source text)
returns text
language sql
immutable
set search_path=''
as $$
  select replace(trim(coalesce(p_source,'')), E'\\', '/');
$$;

create or replace function private.brain_remote_source_allowed(p_source text)
returns boolean
language plpgsql
immutable
set search_path=''
as $$
declare
  v text := private.brain_remote_normalize_source(p_source);
  v_base text;
  v_ext text;
begin
  if v='' or position(chr(0) in v)>0 or v ~ '^/' or v ~ '(^|/)\.\.(/|$)' then
    return false;
  end if;
  if v ~ '(^|/)(\.git|node_modules|__pycache__|\.venv|venv)(/|$)' then
    return false;
  end if;
  v_base := lower(regexp_replace(v, '^.*/', ''));
  if v_base in (
    '.env','.env.local','.env.production','.npmrc','.netrc',
    'config.local.json','credentials','credentials.json','service-account.json',
    'id_rsa','id_ed25519'
  ) or v_base like 'id_rsa%' or v_base like 'id_ed25519%' then
    return false;
  end if;
  v_ext := lower(coalesce(substring(v_base from '(\.[^.]+)$'),''));
  if v_ext in ('.pem','.key','.p12','.pfx','.sqlite','.sqlite3','.db') then
    return false;
  end if;
  return true;
end;
$$;

create or replace function private.brain_remote_source_writable(p_source text)
returns boolean
language plpgsql
immutable
set search_path=''
as $$
declare
  v text := private.brain_remote_normalize_source(p_source);
  v_base text;
  v_ext text;
begin
  if not private.brain_remote_source_allowed(v) then return false; end if;
  if v ~ '(^|/)\.[^/]+(/|$)' then return false; end if;
  v_base := lower(regexp_replace(v, '^.*/', ''));
  v_ext := lower(coalesce(substring(v_base from '(\.[^.]+)$'),''));
  return v_ext in ('.md','.txt','.json','.yaml','.yml','.toml','.csv','.tsv');
end;
$$;

create or replace function private.brain_remote_sha(p_content text)
returns text
language sql
immutable
set search_path=''
as $$
  select encode(extensions.digest(convert_to(coalesce(p_content,''),'UTF8'),'sha256'),'hex');
$$;

create or replace function private.brain_remote_tree_hash()
returns text
language sql
stable
set search_path=''
as $$
  select encode(
    extensions.digest(
      convert_to(
        coalesce(string_agg(f.source || ':' || f.sha256, E'\n' order by f.source),''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  from private.brain_remote_files f
  where not f.deleted;
$$;

create or replace function private.brain_remote_put_blob(p_content text)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  v_sha text := private.brain_remote_sha(p_content);
begin
  insert into private.brain_remote_blobs(sha256,content,size_bytes)
  values(v_sha,coalesce(p_content,''),octet_length(convert_to(coalesce(p_content,''),'UTF8')))
  on conflict(sha256) do nothing;
  return v_sha;
end;
$$;

create or replace function private.brain_remote_apply_change(
  p_commit_id uuid,
  p_source text,
  p_base_sha256 text,
  p_content text,
  p_deleted boolean,
  p_actor text,
  p_origin text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_source text := private.brain_remote_normalize_source(p_source);
  v_file private.brain_remote_files;
  v_remote_sha text;
  v_incoming_sha text;
  v_seq bigint;
  v_conflict uuid;
  v_kind text;
begin
  if not private.brain_remote_source_allowed(v_source) then
    raise exception 'remote vault source denied';
  end if;
  if p_base_sha256 is not null and p_base_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid base sha256';
  end if;

  select * into v_file
  from private.brain_remote_files
  where source=v_source
  for update;

  v_remote_sha := case when v_file.source is null or v_file.deleted then null else v_file.sha256 end;

  if coalesce(v_remote_sha,'') <> coalesce(p_base_sha256,'') then
    if p_deleted then
      v_incoming_sha := private.brain_remote_put_blob('');
    else
      v_incoming_sha := private.brain_remote_put_blob(coalesce(p_content,''));
    end if;
    insert into private.brain_remote_conflicts(
      source,base_sha256,remote_sha256,incoming_sha256,actor,origin
    ) values(
      v_source,p_base_sha256,v_remote_sha,v_incoming_sha,p_actor,p_origin
    ) returning id into v_conflict;

    return jsonb_build_object(
      'status','conflict','conflict_id',v_conflict,'source',v_source,
      'base_sha256',p_base_sha256,'remote_sha256',v_remote_sha,'incoming_sha256',v_incoming_sha
    );
  end if;

  if p_deleted then
    if v_remote_sha is null then
      return jsonb_build_object('status','noop','source',v_source,'sha256',null);
    end if;
    update private.brain_remote_files
    set sha256=null,deleted=true,revision=revision+1,updated_by=p_actor,updated_at=now()
    where source=v_source;
    v_kind := 'delete';
    v_incoming_sha := null;
  else
    v_incoming_sha := private.brain_remote_put_blob(coalesce(p_content,''));
    if v_remote_sha = v_incoming_sha then
      return jsonb_build_object('status','noop','source',v_source,'sha256',v_incoming_sha);
    end if;
    v_kind := case when v_remote_sha is null then 'add' else 'modify' end;
    insert into private.brain_remote_files(source,sha256,revision,deleted,updated_by,updated_at)
    values(v_source,v_incoming_sha,1,false,p_actor,now())
    on conflict(source) do update
      set sha256=excluded.sha256,
          revision=private.brain_remote_files.revision+1,
          deleted=false,
          updated_by=excluded.updated_by,
          updated_at=excluded.updated_at;
  end if;

  insert into private.brain_remote_changes(commit_id,source,old_sha256,new_sha256,change_kind)
  values(p_commit_id,v_source,v_remote_sha,v_incoming_sha,v_kind)
  returning seq into v_seq;

  return jsonb_build_object(
    'status','applied','source',v_source,'seq',v_seq,'change_kind',v_kind,
    'previous_sha256',v_remote_sha,'sha256',v_incoming_sha
  );
end;
$$;

create or replace function private.brain_remote_finish_commit(p_commit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_seq bigint;
  v_tree text;
begin
  select max(seq) into v_seq
  from private.brain_remote_changes
  where commit_id=p_commit_id;

  if v_seq is null then
    delete from private.brain_remote_commits where id=p_commit_id;
    select tree_hash into v_tree from private.brain_remote_meta where singleton=true;
    return jsonb_build_object('changed',false,'head_seq',(select head_seq from private.brain_remote_meta where singleton=true),'tree_hash',v_tree);
  end if;

  v_tree := private.brain_remote_tree_hash();
  update private.brain_remote_meta
  set head_commit=p_commit_id,head_seq=v_seq,tree_hash=v_tree,updated_at=now()
  where singleton=true;

  return jsonb_build_object('changed',true,'head_commit',p_commit_id,'head_seq',v_seq,'tree_hash',v_tree);
end;
$$;

create or replace function public.brain_remote_status()
returns jsonb
language sql
security definer
stable
set search_path=''
as $$
  select jsonb_build_object(
    'initialized', exists(select 1 from private.brain_remote_files),
    'head_commit', m.head_commit,
    'head_seq', m.head_seq,
    'tree_hash', m.tree_hash,
    'file_count', (select count(*) from private.brain_remote_files f where not f.deleted),
    'open_conflicts', (select count(*) from private.brain_remote_conflicts c where c.status='open'),
    'updated_at', m.updated_at
  )
  from private.brain_remote_meta m
  where m.singleton=true;
$$;

create or replace function public.brain_remote_vault_get(p_source text)
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  v_source text := private.brain_remote_normalize_source(p_source);
  v_file private.brain_remote_files;
  v_blob private.brain_remote_blobs;
begin
  if not private.brain_remote_source_allowed(v_source) then raise exception 'remote vault source denied'; end if;
  select * into v_file from private.brain_remote_files where source=v_source and not deleted;
  if v_file.source is null then return null; end if;
  select * into v_blob from private.brain_remote_blobs where sha256=v_file.sha256;
  return jsonb_build_object(
    'source',v_source,'sha256',v_file.sha256,'revision',v_file.revision,
    'size_bytes',v_blob.size_bytes,'content',v_blob.content,
    'writable',private.brain_remote_source_writable(v_source),
    'remote_head_seq',(select head_seq from private.brain_remote_meta where singleton=true)
  );
end;
$$;

create or replace function public.brain_remote_vault_list(
  p_path text default null,
  p_recursive boolean default true,
  p_max_entries integer default 500
) returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  v_path text := trim(both '/' from private.brain_remote_normalize_source(coalesce(p_path,'')));
  v_limit integer := least(greatest(coalesce(p_max_entries,500),1),2000);
  v_entries jsonb;
  v_count integer;
begin
  select count(*) into v_count
  from private.brain_remote_files f
  where not f.deleted
    and (v_path='' or f.source=v_path or f.source like v_path || '/%')
    and (coalesce(p_recursive,true) or position('/' in substring(f.source from length(v_path)+2))=0);

  select coalesce(jsonb_agg(x order by x->>'source'),'[]'::jsonb)
  into v_entries
  from (
    select jsonb_build_object(
      'source',f.source,'sha256',f.sha256,'revision',f.revision,
      'size_bytes',b.size_bytes,'writable',private.brain_remote_source_writable(f.source)
    ) x
    from private.brain_remote_files f
    join private.brain_remote_blobs b on b.sha256=f.sha256
    where not f.deleted
      and (v_path='' or f.source=v_path or f.source like v_path || '/%')
      and (coalesce(p_recursive,true) or position('/' in substring(f.source from length(v_path)+2))=0)
    order by f.source
    limit v_limit
  ) q;

  return jsonb_build_object(
    'path',case when v_path='' then '.' else v_path end,
    'recursive',coalesce(p_recursive,true),'truncated',v_count>v_limit,'entries',v_entries,
    'remote_head_seq',(select head_seq from private.brain_remote_meta where singleton=true)
  );
end;
$$;

create or replace function public.brain_remote_vault_find(
  p_query text,
  p_path text default null,
  p_max_results integer default 100
) returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  v_query text := lower(trim(coalesce(p_query,'')));
  v_path text := trim(both '/' from private.brain_remote_normalize_source(coalesce(p_path,'')));
  v_limit integer := least(greatest(coalesce(p_max_results,100),1),500);
  v_matches jsonb;
  v_count integer;
begin
  if v_query='' then raise exception 'query is required'; end if;
  select count(*) into v_count
  from private.brain_remote_files f
  where not f.deleted
    and lower(f.source) like '%' || v_query || '%'
    and (v_path='' or f.source=v_path or f.source like v_path || '/%');

  select coalesce(jsonb_agg(x order by x->>'source'),'[]'::jsonb)
  into v_matches
  from (
    select jsonb_build_object(
      'source',f.source,'sha256',f.sha256,'revision',f.revision,
      'size_bytes',b.size_bytes,'writable',private.brain_remote_source_writable(f.source)
    ) x
    from private.brain_remote_files f
    join private.brain_remote_blobs b on b.sha256=f.sha256
    where not f.deleted
      and lower(f.source) like '%' || v_query || '%'
      and (v_path='' or f.source=v_path or f.source like v_path || '/%')
    order by f.source
    limit v_limit
  ) q;

  return jsonb_build_object('query',p_query,'path',case when v_path='' then '.' else v_path end,'truncated',v_count>v_limit,'matches',v_matches);
end;
$$;

create or replace function public.brain_remote_vault_search(
  p_query text,
  p_path text default null,
  p_case_sensitive boolean default false,
  p_max_results integer default 100,
  p_max_matches_per_file integer default 20
) returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  v_query text := coalesce(p_query,'');
  v_path text := trim(both '/' from private.brain_remote_normalize_source(coalesce(p_path,'')));
  v_limit integer := least(greatest(coalesce(p_max_results,100),1),500);
  v_per_file integer := least(greatest(coalesce(p_max_matches_per_file,20),1),100);
  v_matches jsonb;
begin
  if trim(v_query)='' then raise exception 'query is required'; end if;

  with lines as (
    select f.source,f.sha256,l.line,l.line_no,
      case when coalesce(p_case_sensitive,false)
        then position(v_query in l.line)
        else position(lower(v_query) in lower(l.line))
      end as col
    from private.brain_remote_files f
    join private.brain_remote_blobs b on b.sha256=f.sha256
    cross join lateral regexp_split_to_table(b.content,E'\r?\n') with ordinality as l(line,line_no)
    where not f.deleted
      and (v_path='' or f.source=v_path or f.source like v_path || '/%')
  ), ranked as (
    select *,row_number() over(partition by source order by line_no) as file_rank
    from lines where col>0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source',source,'sha256',sha256,'line',line_no,'column',col,
    'excerpt',case when length(line)<=400 then line else left(line,397)||'...' end
  ) order by source,line_no),'[]'::jsonb)
  into v_matches
  from (select * from ranked where file_rank<=v_per_file order by source,line_no limit v_limit) q;

  return jsonb_build_object(
    'query',v_query,'path',case when v_path='' then '.' else v_path end,
    'case_sensitive',coalesce(p_case_sensitive,false),'matches',v_matches,
    'remote_head_seq',(select head_seq from private.brain_remote_meta where singleton=true)
  );
end;
$$;

create or replace function public.brain_remote_vault_read_range(
  p_source text,
  p_start_line integer,
  p_end_line integer
) returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  v_source text := private.brain_remote_normalize_source(p_source);
  v_sha text;
  v_content text;
  v_total integer;
  v_slice text;
begin
  if p_start_line<1 or p_end_line<p_start_line or p_end_line-p_start_line+1>500 then
    raise exception 'invalid line range';
  end if;
  select f.sha256,b.content into v_sha,v_content
  from private.brain_remote_files f
  join private.brain_remote_blobs b on b.sha256=f.sha256
  where f.source=v_source and not f.deleted;
  if v_sha is null then return null; end if;

  select count(*),string_agg(line,E'\n' order by line_no)
  into v_total,v_slice
  from regexp_split_to_table(v_content,E'\r?\n') with ordinality as x(line,line_no)
  where line_no between p_start_line and p_end_line;

  select count(*) into v_total
  from regexp_split_to_table(v_content,E'\r?\n');

  return jsonb_build_object(
    'source',v_source,'sha256',v_sha,'total_lines',v_total,
    'start_line',p_start_line,'end_line',least(p_end_line,v_total),
    'content',coalesce(v_slice,'')
  );
end;
$$;

create or replace function public.brain_remote_context(
  p_query text,
  p_project text default null,
  p_limit integer default 8,
  p_budget_chars integer default 12000,
  p_audience text default null
) returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  v_query text := trim(coalesce(p_query,''));
  v_limit integer := least(greatest(coalesce(p_limit,8),1),50);
  v_budget integer := least(greatest(coalesce(p_budget_chars,12000),1000),100000);
  v_records jsonb;
  v_conflicts jsonb;
begin
  if v_query='' then raise exception 'query is required'; end if;
  if p_audience is not null and p_audience<>'public' then raise exception 'audience must be public'; end if;

  with q as (select plainto_tsquery('simple',v_query) query),
  candidates as (
    select f.source,f.sha256,b.content,
      ts_rank_cd(b.content_tsv,q.query) as rank,
      ts_headline('simple',b.content,q.query,'MaxWords=90,MinWords=20,ShortWord=2') as excerpt
    from private.brain_remote_files f
    join private.brain_remote_blobs b on b.sha256=f.sha256
    cross join q
    where not f.deleted
      and (b.content_tsv @@ q.query or lower(b.content) like '%'||lower(v_query)||'%' or lower(f.source) like '%'||lower(v_query)||'%')
      and (p_project is null or lower(f.source) like '%'||lower(p_project)||'%' or lower(b.content) like '%project%'||lower(p_project)||'%')
      and (
        p_audience is null
        or (
          b.content !~* 'visibility[[:space:]]*:[[:space:]]*[''"]?private'
          and b.content !~* '"visibility"[[:space:]]*:[[:space:]]*"private"'
        )
      )
    order by rank desc,f.updated_at desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source',source,'sha256',sha256,
    'text',left(excerpt,greatest(200,least(4000,v_budget/v_limit))),
    'kind','remote_shadow'
  )),'[]'::jsonb)
  into v_records
  from candidates;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'source',source,'base_sha256',base_sha256,'remote_sha256',remote_sha256,
    'incoming_sha256',incoming_sha256,'origin',origin,'created_at',created_at
  ) order by created_at),'[]'::jsonb)
  into v_conflicts
  from (
    select * from private.brain_remote_conflicts
    where status='open'
    order by created_at
    limit 20
  ) c;

  return jsonb_build_object(
    'query',v_query,'project',p_project,'records',v_records,
    'citations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'source',r->>'source','sha256',r->>'sha256','kind','remote_shadow'
      ))
      from jsonb_array_elements(v_records) r
    ),'[]'::jsonb),
    'open_conflicts',v_conflicts,
    'remote_head_seq',(select head_seq from private.brain_remote_meta where singleton=true)
  );
end;
$$;

create or replace function public.brain_remote_vault_update(
  p_source text,
  p_expected_sha256 text,
  p_content text,
  p_actor text default 'chatgpt'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_source text := private.brain_remote_normalize_source(p_source);
  v_commit uuid;
  v_result jsonb;
  v_head jsonb;
begin
  if p_expected_sha256 is null or p_expected_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'valid expected sha256 required'; end if;
  if not private.brain_remote_source_writable(v_source) then raise exception 'remote vault source is not writable'; end if;
  if v_source ~* '(^|/)tasks/' or coalesce(p_content,'') ~* '(^|\n)[[:space:]]*kind[[:space:]]*:[[:space:]]*task([[:space:]]|$)' then
    raise exception 'task sources must use brain_task_update';
  end if;

  insert into private.brain_remote_commits(parent_id,actor,origin,message)
  select head_commit,coalesce(nullif(p_actor,''),'chatgpt'),'chatgpt_remote','CAS update '||v_source
  from private.brain_remote_meta where singleton=true
  returning id into v_commit;

  v_result := private.brain_remote_apply_change(v_commit,v_source,p_expected_sha256,coalesce(p_content,''),false,coalesce(nullif(p_actor,''),'chatgpt'),'chatgpt_remote');
  if v_result->>'status'='conflict' then
    delete from private.brain_remote_commits where id=v_commit;
    return v_result;
  end if;
  v_head := private.brain_remote_finish_commit(v_commit);
  return v_result || jsonb_build_object('head',v_head);
end;
$$;

create or replace function public.brain_remote_note_create(
  p_source text,
  p_text text,
  p_metadata jsonb,
  p_actor text default 'chatgpt'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_source text := private.brain_remote_normalize_source(p_source);
  v_content text;
  v_commit uuid;
  v_result jsonb;
  v_head jsonb;
begin
  if jsonb_typeof(p_metadata)<>'object' then raise exception 'metadata must be object'; end if;
  if not private.brain_remote_source_writable(v_source) then raise exception 'remote note source is not writable'; end if;
  if v_source ~* '(^|/)tasks/' or lower(coalesce(p_metadata->>'kind',''))='task' then
    raise exception 'task sources must use brain_task_create';
  end if;
  if exists(select 1 from private.brain_remote_files where source=v_source and not deleted) then
    raise exception 'source already exists';
  end if;

  v_content := E'---\n' || p_metadata::text || E'\n---\n\n' || coalesce(p_text,'');

  insert into private.brain_remote_commits(parent_id,actor,origin,message)
  select head_commit,coalesce(nullif(p_actor,''),'chatgpt'),'chatgpt_remote','Create note '||v_source
  from private.brain_remote_meta where singleton=true
  returning id into v_commit;

  v_result := private.brain_remote_apply_change(v_commit,v_source,null,v_content,false,coalesce(nullif(p_actor,''),'chatgpt'),'chatgpt_remote');
  if v_result->>'status'='conflict' then
    delete from private.brain_remote_commits where id=v_commit;
    return v_result;
  end if;
  v_head := private.brain_remote_finish_commit(v_commit);
  return v_result || jsonb_build_object('head',v_head);
end;
$$;

create or replace function public.brain_remote_conflicts(p_limit integer default 50)
returns jsonb
language sql
security definer
stable
set search_path=''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'source',c.source,'base_sha256',c.base_sha256,
    'remote_sha256',c.remote_sha256,'incoming_sha256',c.incoming_sha256,
    'base_content',bb.content,'remote_content',rb.content,'incoming_content',ib.content,
    'actor',c.actor,'origin',c.origin,'created_at',c.created_at
  ) order by c.created_at),'[]'::jsonb)
  from (
    select * from private.brain_remote_conflicts
    where status='open'
    order by created_at
    limit least(greatest(coalesce(p_limit,50),1),100)
  ) c
  left join private.brain_remote_blobs bb on bb.sha256=c.base_sha256
  left join private.brain_remote_blobs rb on rb.sha256=c.remote_sha256
  join private.brain_remote_blobs ib on ib.sha256=c.incoming_sha256;
$$;

create or replace function public.brain_remote_replica_status(p_replica_id text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_replica private.brain_remote_replicas;
  v_meta private.brain_remote_meta;
begin
  if not private.brain_remote_worker_ok() then raise exception 'unauthorized worker'; end if;
  if trim(coalesce(p_replica_id,''))='' then raise exception 'replica id required'; end if;
  insert into private.brain_remote_replicas(replica_id) values(p_replica_id)
  on conflict(replica_id) do update set last_seen_at=now()
  returning * into v_replica;
  select * into v_meta from private.brain_remote_meta where singleton=true;
  return jsonb_build_object(
    'replica_id',p_replica_id,'last_seq',v_replica.last_seq,'replica_tree_hash',v_replica.tree_hash,
    'initialized',exists(select 1 from private.brain_remote_files),
    'head_seq',v_meta.head_seq,'tree_hash',v_meta.tree_hash,
    'open_conflicts',(select count(*) from private.brain_remote_conflicts where status='open')
  );
end;
$$;

create or replace function public.brain_remote_replica_pull(
  p_replica_id text,
  p_after_seq bigint,
  p_limit integer default 500
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,500),1),2000);
  v_changes jsonb;
  v_meta private.brain_remote_meta;
begin
  if not private.brain_remote_worker_ok() then raise exception 'unauthorized worker'; end if;
  if trim(coalesce(p_replica_id,''))='' then raise exception 'replica id required'; end if;
  if coalesce(p_after_seq,0)<0 then raise exception 'invalid after seq'; end if;

  insert into private.brain_remote_replicas(replica_id) values(p_replica_id)
  on conflict(replica_id) do update set last_seen_at=now();

  select coalesce(jsonb_agg(jsonb_build_object(
    'seq',c.seq,'commit_id',c.commit_id,'source',c.source,'old_sha256',c.old_sha256,
    'new_sha256',c.new_sha256,'change_kind',c.change_kind,'content',b.content
  ) order by c.seq),'[]'::jsonb)
  into v_changes
  from (
    select * from private.brain_remote_changes
    where seq>coalesce(p_after_seq,0)
    order by seq
    limit v_limit
  ) c
  left join private.brain_remote_blobs b on b.sha256=c.new_sha256;

  select * into v_meta from private.brain_remote_meta where singleton=true;
  return jsonb_build_object(
    'replica_id',p_replica_id,'after_seq',coalesce(p_after_seq,0),
    'head_seq',v_meta.head_seq,'tree_hash',v_meta.tree_hash,
    'has_more',v_meta.head_seq>coalesce((select max((x->>'seq')::bigint) from jsonb_array_elements(v_changes) x),coalesce(p_after_seq,0)),
    'changes',v_changes
  );
end;
$$;

create or replace function public.brain_remote_replica_push(
  p_replica_id text,
  p_changes jsonb,
  p_actor text default 'termux'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_commit uuid;
  v_item jsonb;
  v_results jsonb := '[]'::jsonb;
  v_result jsonb;
  v_head jsonb;
begin
  if not private.brain_remote_worker_ok() then raise exception 'unauthorized worker'; end if;
  if trim(coalesce(p_replica_id,''))='' then raise exception 'replica id required'; end if;
  if jsonb_typeof(p_changes)<>'array' or jsonb_array_length(p_changes)>250 then
    raise exception 'changes must be an array with at most 250 entries';
  end if;

  insert into private.brain_remote_replicas(replica_id) values(p_replica_id)
  on conflict(replica_id) do update set last_seen_at=now();

  insert into private.brain_remote_commits(parent_id,actor,origin,message)
  select head_commit,coalesce(nullif(p_actor,''),'termux'),'replica:'||p_replica_id,'Replica push'
  from private.brain_remote_meta where singleton=true
  returning id into v_commit;

  for v_item in select value from jsonb_array_elements(p_changes)
  loop
    v_result := private.brain_remote_apply_change(
      v_commit,
      v_item->>'source',
      nullif(v_item->>'base_sha256',''),
      coalesce(v_item->>'content',''),
      coalesce((v_item->>'deleted')::boolean,false),
      coalesce(nullif(p_actor,''),'termux'),
      'replica:'||p_replica_id
    );
    v_results := v_results || jsonb_build_array(v_result);
  end loop;

  v_head := private.brain_remote_finish_commit(v_commit);
  return jsonb_build_object('results',v_results,'head',v_head);
end;
$$;

create or replace function public.brain_remote_replica_ack(
  p_replica_id text,
  p_seq bigint,
  p_tree_hash text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_meta private.brain_remote_meta;
begin
  if not private.brain_remote_worker_ok() then raise exception 'unauthorized worker'; end if;
  select * into v_meta from private.brain_remote_meta where singleton=true;
  if p_seq<0 or p_seq>v_meta.head_seq then raise exception 'invalid replica seq'; end if;
  insert into private.brain_remote_replicas(replica_id,last_seq,tree_hash,last_seen_at)
  values(p_replica_id,p_seq,p_tree_hash,now())
  on conflict(replica_id) do update
    set last_seq=greatest(private.brain_remote_replicas.last_seq,excluded.last_seq),
        tree_hash=excluded.tree_hash,last_seen_at=now();
  return jsonb_build_object('replica_id',p_replica_id,'last_seq',p_seq,'tree_hash',p_tree_hash);
end;
$$;

-- Keep the current queue transport compatible, but advertise the optional shadow.
create or replace function public.bridge_transport_contract()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_version integer;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then raise exception 'unauthorized worker'; end if;

  select schema_version into v_version
  from private.bridge_transport_meta
  where singleton=true;

  return jsonb_build_object(
    'schema_version',v_version,
    'claim_rpc','claim_next_brain_command_v2',
    'claim_wait_rpc','claim_next_brain_command_wait',
    'finish_rpc','finish_brain_command_v2',
    'command_terminal_statuses',jsonb_build_array('completed','failed','conflict'),
    'vault_transport','trusted_supabase_queue',
    'remote_vault',jsonb_build_object(
      'version',1,
      'status_rpc','brain_remote_replica_status',
      'pull_rpc','brain_remote_replica_pull',
      'push_rpc','brain_remote_replica_push',
      'ack_rpc','brain_remote_replica_ack'
    )
  );
end;
$$;

-- Dynamic status is appended outside the contract hash so conflicts can surface even
-- while the Termux worker is offline.
create or replace function public.get_avenox_contract_snapshot()
returns jsonb
language sql
security definer
stable
set search_path=''
as $$
  select case
    when s.singleton then
      s.snapshot || jsonb_build_object(
        'published_at',s.updated_at,
        'remote_vault_status',jsonb_build_object(
          'initialized',exists(select 1 from private.brain_remote_files),
          'head_seq',(select head_seq from private.brain_remote_meta where singleton=true),
          'tree_hash',(select tree_hash from private.brain_remote_meta where singleton=true),
          'open_conflicts',(select count(*) from private.brain_remote_conflicts where status='open'),
          'updated_at',(select updated_at from private.brain_remote_meta where singleton=true)
        )
      )
    else null
  end
  from public.avenox_contract_snapshot s
  where s.singleton=true;
$$;

revoke all on function public.brain_remote_status() from public,anon,authenticated;
revoke all on function public.brain_remote_vault_get(text) from public,anon,authenticated;
revoke all on function public.brain_remote_vault_list(text,boolean,integer) from public,anon,authenticated;
revoke all on function public.brain_remote_vault_find(text,text,integer) from public,anon,authenticated;
revoke all on function public.brain_remote_vault_search(text,text,boolean,integer,integer) from public,anon,authenticated;
revoke all on function public.brain_remote_vault_read_range(text,integer,integer) from public,anon,authenticated;
revoke all on function public.brain_remote_context(text,text,integer,integer,text) from public,anon,authenticated;
revoke all on function public.brain_remote_vault_update(text,text,text,text) from public,anon,authenticated;
revoke all on function public.brain_remote_note_create(text,text,jsonb,text) from public,anon,authenticated;
revoke all on function public.brain_remote_conflicts(integer) from public,anon,authenticated;

grant execute on function public.brain_remote_status() to service_role;
grant execute on function public.brain_remote_vault_get(text) to service_role;
grant execute on function public.brain_remote_vault_list(text,boolean,integer) to service_role;
grant execute on function public.brain_remote_vault_find(text,text,integer) to service_role;
grant execute on function public.brain_remote_vault_search(text,text,boolean,integer,integer) to service_role;
grant execute on function public.brain_remote_vault_read_range(text,integer,integer) to service_role;
grant execute on function public.brain_remote_context(text,text,integer,integer,text) to service_role;
grant execute on function public.brain_remote_vault_update(text,text,text,text) to service_role;
grant execute on function public.brain_remote_note_create(text,text,jsonb,text) to service_role;
grant execute on function public.brain_remote_conflicts(integer) to service_role;

revoke all on function public.brain_remote_replica_status(text) from public,anon;
revoke all on function public.brain_remote_replica_pull(text,bigint,integer) from public,anon;
revoke all on function public.brain_remote_replica_push(text,jsonb,text) from public,anon;
revoke all on function public.brain_remote_replica_ack(text,bigint,text) from public,anon;
grant execute on function public.brain_remote_replica_status(text) to authenticated;
grant execute on function public.brain_remote_replica_pull(text,bigint,integer) to authenticated;
grant execute on function public.brain_remote_replica_push(text,jsonb,text) to authenticated;
grant execute on function public.brain_remote_replica_ack(text,bigint,text) to authenticated;

revoke all on function public.get_avenox_contract_snapshot() from public,anon;
grant execute on function public.get_avenox_contract_snapshot() to authenticated,service_role;

commit;
