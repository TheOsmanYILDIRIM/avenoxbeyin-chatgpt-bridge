---
name: avenox-chatgpt-bridge-v3
description: ChatGPT Web ile Avenox Beyin arasındaki Bridge API v3 sözleşmesi. Hash'li contract snapshot cache, gerektiğinde queue operasyonları, full-vault erişimi ve güvenli süreklilik davranışını tanımlar.
---

# Avenox ChatGPT Bridge v3

Bu skill güncel ChatGPT ↔ Avenox Beyin çalışma sözleşmesidir.

## Otorite sırası

1. Canlı `contract_hash` ile eşleşen contract snapshot
2. Bu `bridge_skill`
3. Canlı `bridge_capabilities`
4. `core_skill`
5. `skills_manifest`

Operation, payload veya transport davranışı tahmin etme.

## Contract Snapshot Fast Path

Yeni konuşmada ilk anlamlı Avenox/Beyin işi öncesinde önce `public.get_avenox_contract_snapshot()` ile snapshot oku.

Snapshot şunları taşır:
- `contract_hash`
- `contract_version`
- `bridge_skill`
- `bridge_capabilities`
- `core_skill`
- `skills_manifest`
- `worker_commit`
- `brain_version`

Aynı konuşmada `contract_hash` değişmedikçe snapshot'ı tekrar okuma. Konuşma içi cache kullan.

Snapshot yoksa, bozuksa veya açıkça rebuild/refresh gerekiyorsa `avenox_bootstrap` queue operasyonunu fallback olarak kullan.

## Normal Tur Davranışı

Normal konuşmalarda Supabase çağrısı yapma.

`avenox_turn_context` her anlamlı tur öncesi zorunlu değildir. Yalnız:
- explicit refresh,
- recovery,
- debug,
- continuity onarımı

gerektiğinde kullanılır.

Gerçek Beyin işi gerektiğinde yalnız gereken `brain_*` operasyonunu çağır.

## Compact Hook Capsule

Bridge birkaç tamamlanmış ChatGPT-facing yanıtta bir full hook skill yerine kısa contract capsule ekler.

Örnek:
`contract=<hash> v1`

Cached hash aynıysa yeni bootstrap/context refresh yapma. Hash değişirse snapshot'ı bir kez yeniden oku.

Capsule'ın amacı:
- aynı command/job ID'yi korumak,
- progress'i terminal sanmamak,
- yalnız kalıcı ve anlamlı state değişikliklerini persist etmek,
- full skill metnini tekrar tekrar taşımamaktır.

## Queue / Result

- `public.brain_commands` yalnız gerçek Beyin operasyonları için kullanılır.
- Oluşturulan command ID'yi takip et.
- `pending`, `claimed`, `running` iken aynı işi duplicate command ile yeniden başlatma.
- `completed`, `failed`, `conflict` terminaldir.
- Aynı command'in `brain_responses` sonucunu kullan.

## Persistence

Yalnız gerçekten gerekli olduğunda yaz:
- görev durumu → `brain_task_update`
- yeni görev → `brain_task_create`
- kalıcı bilgi/karar → `brain_note_create`
- companion dosyaları → exact read + `brain_vault_update`
- tamamlanmış iş kanıtı → `brain_receipt`

Salt okuma, genel soru, geçici fikir fırtınası veya kullanıcının no-memory talebinde yazma yapma.

`avenox_turn_finalize` yalnız bu tur gerçekten `avenox_turn_context` ile tracked turn açtıysa kullanılır. Snapshot-cached normal turlarda zorunlu değildir.

## Full Vault

`brain_vault_list`, `brain_vault_find`, `brain_vault_search`, `brain_vault_read_range`, `brain_vault_get`, `brain_vault_update` normal authenticated queue/result akışıyla çalışır.

- unknown path → `brain_vault_find`
- literal content search → `brain_vault_search`
- bounded lines → `brain_vault_read_range`
- whole file → `brain_vault_get`
- write → exact read + SHA-256 CAS `brain_vault_update`

Task dosyalarını generic vault update ile değiştirme; `brain_task_update` kullan.

Bridge remote shell değildir. Path traversal, symlink escape, credential/runtime denylist ve binary restrictions korunur.

## Recovery

Yeni oturumda açık iş gerekiyorsa queue'daki gerçek command/job durumunu incele. Aktif işi duplicate başlatma.

`recent_task_journal` gerekirse `avenox_bootstrap` veya explicit recovery context üzerinden alınabilir; normal her turda taşınmaz.

## Kaynak Önceliği

1. canlı Avenox Brain
2. güncel proje source code için GitHub
3. Bridge gerekli Brain kaynağını sağlayamıyorsa uygun fallback

Bilgi yoksa uydurma.
