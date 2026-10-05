begin;
create index if not exists brain_vault_heads_sha_idx
  on private.brain_vault_heads(sha256);
create index if not exists brain_vault_heads_commit_idx
  on private.brain_vault_heads(commit_seq);
commit;
