-- Track worker liveness so ChatGPT can distinguish an offline worker from a slow command.

alter table private.bridge_workers
  add column if not exists last_seen_at timestamptz;

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
  where w.user_id=v_uid and w.enabled;

  if v_worker is null then
    raise exception 'unauthorized worker';
  end if;

  update private.bridge_workers
  set last_seen_at=now()
  where user_id=v_uid and enabled;

  return query
  with candidate as (
    select c.id
    from public.brain_commands c
    where c.status='pending'
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

create or replace function private.brain_worker_status(
  p_stale_after_seconds integer default 20
)
returns jsonb
language sql
security invoker
set search_path=''
as $$
  select coalesce(
    (
      select jsonb_strip_nulls(jsonb_build_object(
        'worker_name', w.worker_name,
        'enabled', w.enabled,
        'last_seen_at', w.last_seen_at,
        'heartbeat_age_seconds',
          case
            when w.last_seen_at is null then null
            else greatest(0, floor(extract(epoch from (clock_timestamp() - w.last_seen_at))))::bigint
          end,
        'stale_after_seconds', greatest(coalesce(p_stale_after_seconds, 20), 5),
        'online',
          coalesce(
            w.last_seen_at >= clock_timestamp() - make_interval(
              secs => greatest(coalesce(p_stale_after_seconds, 20), 5)
            ),
            false
          )
      ))
      from private.bridge_workers w
      where w.enabled
      order by w.last_seen_at desc nulls last, w.created_at desc
      limit 1
    ),
    jsonb_build_object(
      'online', false,
      'reason', 'no_enabled_worker',
      'stale_after_seconds', greatest(coalesce(p_stale_after_seconds, 20), 5)
    )
  );
$$;

revoke all on function private.brain_worker_status(integer)
  from public, anon, authenticated;
