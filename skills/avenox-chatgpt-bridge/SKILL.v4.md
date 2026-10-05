---
name: avenox-chatgpt-bridge-v4
description: ChatGPT ↔ Avenox Beyin remote-first Bridge API v4 sözleşmesi.
---

# Avenox ChatGPT Bridge v4

## Otorite
Canlı contract snapshot otoritedir. Sıra: `contract_hash` → `bridge_skill` → `bridge_capabilities` → `core_skill` → `skills_manifest`. Operation, payload veya transport uydurma.

İlk anlamlı Avenox/Beyin işinde `public.get_avenox_contract_snapshot()` çağır. Aynı konuşmada hash değişmedikçe tekrar snapshot/bootstrap alma. `avenox_bootstrap` yalnız snapshot yok/bozuksa, hash değişmişse veya açık recovery/debug gerekiyorsa kullanılır. Normal turlarda `avenox_turn_context` çağırma.

## Remote-first Brain
Snapshot içindeki `remote_vault_status`, versioned remote Brain HEAD'in canlı durumudur.

Remote vault seed edilmişse:
- `brain_context` ve `brain_vault_list/find/search/read_range/get/update` için Termux gerekmez.
- Bunlar Supabase'teki güncel versioned HEAD üzerinde çalışır.
- Okumalar kaynak SHA/commit bilgisi taşır.
- Normal vault yazıları SHA-256 CAS ile yapılır; stale yazı sessizce ezilmez.
- Task kaynakları generic vault update ile yazılmaz; `brain_task_update` semantiği korunur.

`remote_vault_status.open_conflicts > 0` ise ilk anlamlı Brain işinde `brain_remote_conflicts` ile BASE/LOCAL/REMOTE varyantlarını oku. Zaman damgasına bakarak otomatik kazanan seçme. Kaynağın semantiğini koruyarak birleştir; task çatışmalarını task revision akışını atlayarak ham dosya yazımıyla çözme.

## Termux replica
Termux canonical sunucu değildir; local replica + Beyin/AGY worker'dır. Worker açıldığında:
1. küçük remote HEAD'i karşılaştırır,
2. local mtime/SHA cache'inden yalnız değişen dosyaları yeniden hashler,
3. remote commit cursor'ından yalnız yeni path değişikliklerini çeker,
4. üçlü karşılaştırma yapar: BASE / LOCAL / REMOTE,
5. temiz değişiklikleri uygular, gerçek divergence'ı conflict olarak iki tarafı da koruyarak bırakır,
6. tek `beyin.py sync` ile yerel indeksi tazeler.

İlk seed tüm uygun metin kaynaklarını bir kez yükleyebilir. Sonraki senkronlar delta-only'dir. Yerel silme varsayılan olarak destructive delete sayılmaz; remote kopya geri getirilir.

## Semantic Beyin işlemleri
Beyin'in avantajlarını koru:
- görev → `brain_task_create/update`
- kalıcı bilgi → `brain_note_create`
- tamamlanmış iş kanıtı → `brain_receipt`
- companion/vault → exact read + CAS update
- arama/hatırlama → kaynaklı `brain_context`

Task/note/receipt gibi resmi Beyin işlemleri worker gerektiriyorsa Termux kapalıyken aynı command ID ile `pending` kalabilir. Bu kalıcı deferred iştir: duplicate oluşturma, tamamlanmış gibi sunma. Termux yeniden açıldığında aynı command uygulanır ve sonuç remote vault'a delta olarak yansır.

## Queue
Bir operasyon için oluşturulan command ID'yi terminal duruma kadar koru. `pending|claimed|running` iken yeni duplicate command oluşturma. `completed|failed|conflict` terminaldir.

## Güvenlik ve gizlilik
Remote vault yalnız güvenli metin kaynaklarını mirrorlar; credential/runtime/binary denylist korunur. Otomatik `brain_context`, `visibility: private`, `remote_allowed: false` ve hassas sensitivity kayıtlarını bağlama katmaz. Exact trusted vault okumaları ayrı yetki sınırındadır. Bridge remote shell değildir.

## Recovery ve hız
Aktif command/job varsa yeniden başlatma. Aynı gerçeği DB/AGY/GitHub üzerinden tekrar tekrar doğrulama. Bilgi yoksa uydurma.
