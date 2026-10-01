---
name: chatgpt-beyin-hook
description: ChatGPT Web/Android için düşük maliyetli Avenox süreklilik sözleşmesi. Snapshot cache, compact hook capsule, gerektiğinde queue operasyonları ve seçici persistence kurallarını tanımlar.
---

# ChatGPT Beyin Hook

## Normal Durum

- Aynı konuşmada geçerli `contract_hash` değişmedikçe contract snapshot'ı yeniden okuma.
- Normal turda `avenox_turn_context` çağırma.
- Gerçek Beyin işi yoksa Supabase çağrısı yapma.
- Capability/payload bilgisini canlı contract snapshot'tan al; tahmin etme.

## Contract Refresh

Yalnız şu durumlarda snapshot yenile:
- compact capsule'daki hash cached hash'ten farklıysa,
- snapshot eksik/bozuksa,
- kullanıcı explicit refresh/recovery/debug istediyse,
- Bridge upgrade sonrası sözleşme değişmişse.

Snapshot fast path başarısızsa `avenox_bootstrap` fallback'tir.

## Queue Takibi

Bir command başlatıldığında aynı command ID'yi takip et.

- `pending | claimed | running` → aynı ID ile devam et.
- `completed | failed | conflict` → terminal.
- Aynı işi aktifken yeni command ile başlatma.

## Persistence

Yazma yalnız kalıcı bir state değişikliği varsa yapılır:
- görev oluşturma/güncelleme,
- kalıcı mimari veya kavramsal karar,
- companion continuity güncellemesi,
- kaynaklı receipt.

Yazma yapılmayan örnekler:
- selamlaşma,
- genel soru-cevap,
- geçici fikir fırtınası,
- salt okuma,
- kullanıcının no-memory/no-tools talebi.

## Companion / Vault

- Exact read gerekiyorsa `brain_vault_get`.
- Yol bilinmiyorsa `brain_vault_find`.
- Metin araması gerekiyorsa `brain_vault_search`.
- Büyük dosyada bounded okuma gerekiyorsa `brain_vault_read_range`.
- Yazmada SHA-256 CAS kullan.
- Task kaynaklarını `brain_task_update` ile değiştir.

Core Beyin skill companion semantiğinde otoritedir.

## Tracked Turn İstisnası

`avenox_turn_context` yalnız explicit refresh/recovery/debug/continuity onarımı için kullanılabilir.

Eğer bu operasyonla tracked turn açıldıysa, o tracked turn sonunda `avenox_turn_finalize` kullan:
- persistence olduysa `state_changed: true` + refs,
- salt okuma ise `state_changed: false` + boş refs.

Tracked turn açılmamış normal snapshot-cached turlarda finalize çağrısı zorunlu değildir.

## Compact Capsule

Bridge periyodik olarak full skill yerine kısa bir capsule ekler:
- `contract=<hash> v<version>`
- active ID'yi koru,
- progress terminal değildir,
- yalnız anlamlı state'i persist et.

Capsule hash'i cached hash ile aynıysa hiçbir refresh yapma.
