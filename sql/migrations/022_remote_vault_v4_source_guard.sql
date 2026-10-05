begin;
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
  if p_source is null or btrim(p_source)='' then
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
commit;
