---
name: avenox-chatgpt-bridge
description: ChatGPT Web ile Avenox Beyin arasındaki Supabase Bridge transport sözleşmesi. Bootstrap, capability discovery, queue/result takibi, source/task güvenliği ve hata davranışlarını tanımlar.
---

# Avenox ChatGPT Bridge

Bu skill, ChatGPT'nin Avenox Beyin'e Bridge üzerinden nasıl erişeceğini tanımlar.

## Otorite sırası

Bir Avenox görevinde şu sırayı kullan:

1. Bu `bridge_skill`: transport ve istemci davranışı.
2. Canlı `bridge_capabilities`: kullanılabilir operation adları, payload şemaları ve intent gereksinimleri.
3. `core_skill`: Avenox Beyin çalışma kuralları.
4. `skills_manifest`: yalnız görev için gerekli ek skill'leri keşfetmek için.

Statik operation listesi ezberleme. `bridge_capabilities` canlı otoritedir.

## Bootstrap

Her yeni konuşmada ilk anlamlı Avenox/Beyin görevinden önce `avenox_bootstrap` çalıştır.

Basit selamlaşma ve sosyal sohbet için bootstrap gerekmez.

Bootstrap sonucunu o konuşmanın güncel sözleşmesi kabul et.

## Capability kullanımı

- Yalnız `available: true` operasyonları kullan.
- Payload'ı ilgili `payload_schema` ile oluştur.
- Operation veya payload alanı tahmin etme.
- `user_intent_required: true` ise açık kullanıcı isteği olmadan çalıştırma.
- Görev gerçekten ek skill gerektiriyorsa yalnız ilgili `avenox_skill_get` çağrısını yap.

## Queue / result akışı

Bridge'in mevcut komut kuyruğunu kullan.

- Bir kullanıcı işi için yalnız gerekli command'i oluştur.
- Enqueue sırasında transport alanlarını gereksiz yere elle üretme; veritabanı defaultlarını kullan.
- Oluşturulan command ID'yi sakla ve yalnız o command'in durumunu/sonucunu takip et.
- Aynı işi duplicate command oluşturarak yeniden başlatma.
- Worker polling'i için yeterli süre bekle.
- `pending`, `claimed` veya `running` ise kullanıcıdan "devam et" isteme; aynı assistant turunda aynı command ID'yi yeniden kontrol et.
- `completed`, `failed` veya `conflict` terminal sonuçlarını esas al.
- Stale/crash recovery Bridge/worker sorumluluğudur; istemci stale command'i körlemesine tekrar çalıştırmaz.

## Exact source ve task güvenliği

Exact Markdown gerektiğinde capability kataloğundaki source operasyonlarını kullan.

Mevcut Markdown düzenlemesinde:
1. önce exact source oku,
2. dönen SHA-256 değerini kullan,
3. CAS korumalı source update yap.

SHA-256 burada transport anahtarı değil, eşzamanlı değişiklik/yanlış overwrite korumasıdır.

Task kaynaklarını generic source update ile değiştirme. Task değişiklikleri resmi task operasyonlarıyla yapılır.

## Kaynak önceliği

1. Canlı Avenox Brain
2. Güncel proje source code için GitHub
3. Bridge gerekli Brain kaynağını sağlayamıyorsa Google Drive fallback

Brain, proje source code kaynağı değildir.

## Hata davranışı

- Bilinmeyen operation veya payload uydurma.
- Bridge terminal hata döndürürse aynı operation'ı yeni command ile otomatik tekrar başlatma.
- Conflict varsa güncel kaynağı/revision'ı yeniden oku ve ancak kullanıcı işi hâlâ geçerliyse güvenli akışla devam et.
- Bridge/worker unavailable görünüyorsa bunu durum olarak belirt; sonuç uydurma.
- Kullanıcıdan yalnız gerçekten kullanıcı kararı gerektiğinde ek mesaj iste.

## Temel ilke

Avenox davranışını statik olarak ezberleme.

Her yeni konuşmada bootstrap'tan:
- `bridge_skill`
- `bridge_capabilities`
- `core_skill`
- `skills_manifest`

alanlarını al ve güncel sözleşme olarak uygula.
