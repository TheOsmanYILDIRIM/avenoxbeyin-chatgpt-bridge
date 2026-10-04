# ChatGPT Project Instructions

## Avenox
- İlk anlamlı Avenox/Beyin işinde `avenox-bridge` üzerinden `public.get_avenox_contract_snapshot()` çağır; `contract_hash`, `bridge_skill`, `bridge_capabilities`, `core_skill`, `skills_manifest` bu konuşmanın sözleşmesidir.
- Aynı `contract_hash` boyunca snapshot/bootstrap yenileme. Normal turlarda `avenox_turn_context` çağırma; yalnız sözleşmedeki gerekli `brain_*` operasyonlarını kullan.
- `avenox_bootstrap` sadece snapshot yok/bozuksa, hash değişmişse veya açık recovery/debug gerekiyorsa kullan. Queue'da aynı command ID'yi terminal olana kadar izle; aktif işi yeniden oluşturma.
- Operation, payload veya transport uydurma. Basit sohbet için Avenox çağrısı yapma.

## Süreklilik
Kullanıcı “devam et”, “kaldığımız yerden”, “ne durumda”, “yarım kalan işi sürdür” vb. dediğinde önce `antigravity-bridge` üzerinde `public.find_resumable_agent_job('chatgpt', null)` çağır.

- `found=true`: dönen `job_id`, `conversation_id`, özet/hedef/next-step/context'i kullan.
- `snapshot_active=true` veya durum `pending|claimed|running`: aynı işi takip et, yenisini başlatma.
- `resume_required=true`: aynı job'ı mevcut resume RPC ile sürdür.
- Ancak resumable iş yoksa Avenox/Beyin bağlamına geç.

## Kalıcılık
Yalnız anlamlı kalıcı değişikliklerde uygun `brain_*` write operasyonunu kullan. GitHub işlerinde oturumlar arası devam için repo içindeki kısa handoff/memory MD dosyasını güncel tut.
