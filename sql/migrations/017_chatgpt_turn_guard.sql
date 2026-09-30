-- 017_chatgpt_turn_guard.sql
-- Migration: Add ChatGPT turn journal table, finish RPC update, and turn lifecycle RPCs

create table if not exists public.chatgpt_turns (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  task text,
  project text,
  status text not null check (status in ('open', 'finalized', 'abandoned')) default 'open',
  state_changed boolean,
  summary text,
  refs text[] default '{}',
  created_at timestamptz not null default now(),
  finalized_at timestamptz
);

create index if not exists idx_chatgpt_turns_user_status_created 
  on public.chatgpt_turns(user_id, status, created_at desc);

create index if not exists idx_chatgpt_turns_user_created 
  on public.chatgpt_turns(user_id, created_at desc);

alter table public.chatgpt_turns enable row level security;

create policy "chatgpt_turns_select_own" on public.chatgpt_turns
  for select using (auth.uid() = user_id);

create policy "chatgpt_turns_insert_own" on public.chatgpt_turns
  for insert with check (auth.uid() = user_id);

create policy "chatgpt_turns_update_own" on public.chatgpt_turns
  for update using (auth.uid() = user_id);

-- Update bridge_commands operation check constraint if present
do \$\$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'bridge_commands_operation_check'
  ) then
    alter table public.bridge_commands drop constraint bridge_commands_operation_check;
    alter table public.bridge_commands add constraint bridge_commands_operation_check check (
      operation in (
        'brain_context',
        'brain_note_create',
        'brain_task_create',
        'brain_task_update',
        'brain_receipt',
        'brain_sync',
        'brain_history',
        'brain_source_get',
        'brain_source_update',
        'brain_vault_list',
        'brain_vault_get',
        'brain_vault_update',
        'brain_vault_find',
        'brain_vault_search',
        'brain_vault_read_range',
        'brain_skill_sync',
        'brain_companion_compact',
        'brain_preferences_get',
        'brain_preferences_update',
        'brain_doctor',
        'brain_update_check',
        'brain_update',
        'brain_update_dismiss',
        'brain_rollback',
        'brain_recover',
        'brain_jev_status',
        'brain_jev_config',
        'brain_jev_memory',
        'avenox_skill_get',
        'avenox_bootstrap',
        'avenox_turn_context',
        'avenox_turn_finalize'
      )
    );
  end if;
end;
\$\$;

-- Update bridge_responses response_kind check constraint if present
do \$\$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'bridge_responses_response_kind_check'
  ) then
    alter table public.bridge_responses drop constraint bridge_responses_response_kind_check;
    alter table public.bridge_responses add constraint bridge_responses_response_kind_check check (
      response_kind in ('context', 'source', 'mutation', 'doctor', 'skill', 'bootstrap', 'turn_context', 'turn_finalize')
    );
  end if;
end;
\$\$;

-- open_chatgpt_turn RPC
create or replace function public.open_chatgpt_turn(
  p_task text default null,
  p_project text default null,
  p_turn_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as \$\$
declare
  v_user_id uuid := auth.uid();
  v_turn_id text := coalesce(nullif(trim(p_turn_id), ''), gen_random_uuid()::text);
  v_prev record;
  v_prev_summary jsonb := null;
begin
  if v_user_id is null then
    raise exception 'authenticated user required';
  end if;

  -- Find most recent open turn for this user that is not the new turn
  select id, task, project, created_at
  into v_prev
  from public.chatgpt_turns
  where user_id = v_user_id
    and status = 'open'
    and id <> v_turn_id
  order by created_at desc
  limit 1;

  if found then
    v_prev_summary := jsonb_build_object(
      'turn_id', v_prev.id,
      'task', v_prev.task,
      'project', v_prev.project,
      'created_at', v_prev.created_at
    );
  end if;

  -- Insert or ensure open turn
  insert into public.chatgpt_turns (id, user_id, task, project, status, created_at)
  values (v_turn_id, v_user_id, p_task, p_project, 'open', now())
  on conflict (id) do update set
    task = coalesce(excluded.task, public.chatgpt_turns.task),
    project = coalesce(excluded.project, public.chatgpt_turns.project);

  return jsonb_build_object(
    'turn_id', v_turn_id,
    'previous_unfinalized_turn', v_prev_summary
  );
end;
\$\$;

-- finalize_chatgpt_turn RPC
create or replace function public.finalize_chatgpt_turn(
  p_turn_id text,
  p_state_changed boolean,
  p_summary text,
  p_refs text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as \$\$
declare
  v_user_id uuid := auth.uid();
  v_turn record;
begin
  if v_user_id is null then
    raise exception 'authenticated user required';
  end if;

  if p_turn_id is null or trim(p_turn_id) = '' then
    raise exception 'turn_id required';
  end if;

  select id, status, state_changed, summary, refs, finalized_at
  into v_turn
  from public.chatgpt_turns
  where id = trim(p_turn_id)
    and user_id = v_user_id;

  if not found then
    -- Record may not exist if created offline or pre-migration, create it directly as finalized
    insert into public.chatgpt_turns (
      id, user_id, status, state_changed, summary, refs, created_at, finalized_at
    )
    values (
      trim(p_turn_id), v_user_id, 'finalized', p_state_changed, p_summary, coalesce(p_refs, '{}'), now(), now()
    );

    return jsonb_build_object(
      'status', 'finalized',
      'turn_id', trim(p_turn_id),
      'idempotent', false
    );
  end if;

  if v_turn.status = 'finalized' then
    return jsonb_build_object(
      'status', 'finalized',
      'turn_id', v_turn.id,
      'idempotent', true
    );
  end if;

  update public.chatgpt_turns
  set
    status = 'finalized',
    state_changed = p_state_changed,
    summary = p_summary,
    refs = coalesce(p_refs, '{}'),
    finalized_at = now()
  where id = v_turn.id;

  return jsonb_build_object(
    'status', 'finalized',
    'turn_id', v_turn.id,
    'idempotent', false
  );
end;
\$\$;
