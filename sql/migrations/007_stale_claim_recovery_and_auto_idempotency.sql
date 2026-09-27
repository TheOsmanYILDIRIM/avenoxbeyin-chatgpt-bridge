-- Make enqueue idempotency automatic and ensure stale claimed/running commands
-- cannot remain stuck forever after a worker crash/restart.

alter table public.brain_commands
  alter column idempotency_key set default gen_random_uuid()::text;

create or replace function public.claim_next_brain_command()
returns setof public.brain_commands
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_worker text;
begin
  select w.worker_name into v_worker
  from private.bridge_workers w
  where w.user_id = v_uid and w.enabled;

  if v_worker is null then
    raise exception 'unauthorized worker';
  end if;

  update public.brain_commands c
  set status='failed',
      error=jsonb_build_object(
        'error','stale_claim_recovered',
        'message','stale claimed/running command was closed before claiming new work'
      ),
      completed_at=now(),
      updated_at=now()
  where c.worker_id=v_uid::text
    and c.status in ('claimed','running')
    and c.updated_at < now() - interval '60 seconds';

  return query
  with candidate as (
    select c.id
    from public.brain_commands c
    where c.status = 'pending'
    order by c.created_at asc
    for update skip locked
    limit 1
  )
  update public.brain_commands c
  set status='claimed',
      worker_id=v_uid::text,
      claimed_at=now(),
      updated_at=now()
  from candidate
  where c.id=candidate.id
  returning c.*;
end;
$$;

revoke all on function public.claim_next_brain_command() from public,anon;
grant execute on function public.claim_next_brain_command() to authenticated;
