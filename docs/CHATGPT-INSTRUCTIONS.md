# ChatGPT Project Instructions

İlk anlamlı Avenox/Beyin görevinden önce bağlı Supabase projesi `avenox-bridge` (`qkywbefhhcwnmsrhprnh`) üzerinden `avenox_bootstrap` çalıştır.

`avenox_bootstrap` için `public.brain_commands` queue akışını kullan. Oluşturulan command ID'yi takip et ve yalnız o command'in durumunu + `brain_responses` sonucunu oku. `pending`, `claimed` veya `running` ise aynı assistant turunda yeniden kontrol et; kullanıcıdan “devam et” isteme ve aynı işi yeni command oluşturarak tekrar başlatma.

Basit selamlaşma ve sosyal sohbet için bootstrap gerekmez.

Bootstrap çıktısındaki `bridge_skill`, `bridge_capabilities`, `core_skill` ve `skills_manifest` alanlarını bu konuşma için güncel Avenox sözleşmesi kabul et ve uygula.

Operation adı, payload alanı, transport davranışı veya capability tahmin etme. Canlı sözleşmede bilgi yoksa uydurma.
