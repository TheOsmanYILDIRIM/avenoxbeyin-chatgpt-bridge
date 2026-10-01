-- 018_contract_snapshot_cache.sql
-- Read-mostly cached Avenox/ChatGPT contract snapshot.

begin;

create table if not exists public.avenox_contract_snapshot (
  singleton boolean primary key default true check (singleton),
  contract_hash text not null check (length(contract_hash) = 64),
  contract_version integer not null check (contract_version > 0),
  snapshot jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.avenox_contract_snapshot enable row level security;
revoke all on public.avenox_contract_snapshot from anon;
grant select on public.avenox_contract_snapshot to authenticated;

drop policy if exists avenox_contract_snapshot_read on public.avenox_contract_snapshot;
create policy avenox_contract_snapshot_read
on public.avenox_contract_snapshot
for select
to authenticated
using (true);

create or replace function public.publish_avenox_contract_snapshot(p_snapshot jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_version integer;
  v_row public.avenox_contract_snapshot;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then
    raise exception 'unauthorized worker';
  end if;

  v_hash := nullif(p_snapshot->>'contract_hash','');
  v_version := nullif(p_snapshot->>'contract_version','')::integer;
  if v_hash is null or length(v_hash) <> 64 or v_version is null or v_version < 1 then
    raise exception 'invalid contract snapshot';
  end if;

  insert into public.avenox_contract_snapshot(singleton,contract_hash,contract_version,snapshot,updated_at)
  values(true,v_hash,v_version,p_snapshot,now())
  on conflict(singleton) do update
    set contract_hash=excluded.contract_hash,
        contract_version=excluded.contract_version,
        snapshot=excluded.snapshot,
        updated_at=case
          when public.avenox_contract_snapshot.contract_hash is distinct from excluded.contract_hash
            or public.avenox_contract_snapshot.contract_version is distinct from excluded.contract_version
          then now()
          else public.avenox_contract_snapshot.updated_at
        end
  returning * into v_row;

  return v_row.snapshot || jsonb_build_object('published_at',v_row.updated_at);
end;
$$;

revoke all on function public.publish_avenox_contract_snapshot(jsonb) from public,anon;
grant execute on function public.publish_avenox_contract_snapshot(jsonb) to authenticated;

create or replace function public.get_avenox_contract_snapshot()
returns jsonb
language sql
security definer
stable
set search_path=''
as $$
  select case
    when s.singleton then
      s.snapshot || jsonb_build_object('published_at',s.updated_at)
    else null
  end
  from public.avenox_contract_snapshot s
  where s.singleton=true;
$$;

revoke all on function public.get_avenox_contract_snapshot() from public,anon;
grant execute on function public.get_avenox_contract_snapshot() to authenticated;

commit;
