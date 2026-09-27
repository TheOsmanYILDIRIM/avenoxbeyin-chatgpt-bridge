-- Remove idle heartbeat writes.
-- Worker availability is inferred only when a real command remains unclaimed across the normal retry window.

drop function if exists private.brain_worker_status(integer);

alter table private.bridge_workers
  drop column if exists last_seen_at;

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
