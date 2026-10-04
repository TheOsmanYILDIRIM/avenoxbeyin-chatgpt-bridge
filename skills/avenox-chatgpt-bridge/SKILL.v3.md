---
name: avenox-chatgpt-bridge-v3
description: ChatGPT ↔ Avenox Beyin Bridge API v3 sözleşmesi.
---

# Avenox ChatGPT Bridge v3

## Otorite
Canlı contract snapshot otoritedir. Sıra: `contract_hash` → `bridge_skill` → `bridge_capabilities` → `core_skill` → `skills_manifest`. Operation, payload veya transport uydurma.

## Snapshot
İlk anlamlı Avenox/Beyin işinde `public.get_avenox_contract_snapshot()` çağır. Aynı konuşmada hash değişmedikçe tekrar okuma.

`avenox_bootstrap` yalnız:
- snapshot yok/bozuksa,
- hash değişip rebuild gerekiyorsa,
- açık recovery/debug gerekiyorsa
kullanılır.

Normal turlarda `avenox_turn_context` çağırma. Gerektiğinde yalnız sözleşmedeki ilgili `brain_*` operasyonunu kullan.

## Queue
Bir operasyon için oluşturulan command ID'yi koru. `pending|claimed|running` iken yeni duplicate command oluşturma; aynı command'in sonucunu izle. `completed|failed|conflict` terminaldir.

## Persistence
Yalnız anlamlı kalıcı state değişikliklerini yaz:
- görev → `brain_task_create/update`
- kalıcı bilgi → `brain_note_create`
- companion/vault → exact read + CAS `brain_vault_update`
- tamamlanmış iş kanıtı → `brain_receipt`

Salt okuma, genel soru, fikir fırtınası veya no-memory isteğinde yazma yapma. `avenox_turn_finalize` yalnız gerçekten tracked turn açıldıysa kullanılır.

## Vault
Path bul → `brain_vault_find`; içerik ara → `brain_vault_search`; satır aralığı → `brain_vault_read_range`; tam dosya → `brain_vault_get`; yaz → SHA-256 CAS `brain_vault_update`. Task dosyalarında `brain_task_update` kullan.

Bridge remote shell değildir; mevcut path/credential/binary güvenlik sınırlarını koru.

## Recovery ve hız
Aktif command/job varsa yeniden başlatma. Gerekmedikçe bootstrap/context çağrısı yapma. Aynı kaynaktan bağımsız okumaları grupla; aynı gerçeği DB/AGY/GitHub üzerinden tekrar tekrar doğrulama. Uzun AGY işinde tek job_id'yi terminal duruma kadar takip et; yalnız gerçek faz değişimlerini kullanıcıya göster.

Bilgi yoksa uydurma.
