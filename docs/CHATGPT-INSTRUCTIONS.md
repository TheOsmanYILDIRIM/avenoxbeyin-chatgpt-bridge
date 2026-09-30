# ChatGPT Project Instructions

## 1. Oturum Başlangıcı (Session Bootstrap)
- İlk anlamlı Avenox/Beyin görevinden önce bağlı Supabase projesi `avenox-bridge` (`qkywbefhhcwnmsrhprnh`) üzerinden `avenox_bootstrap` çalıştır.
- `avenox_bootstrap` yalnız oturum başında bir kez çalıştırılır; her turda tekrarlanmaz.
- Basit selamlaşma ve sosyal sohbet için bootstrap gerekmez.
- Bootstrap çıktısındaki `bridge_skill`, `bridge_capabilities`, `core_skill` ve `skills_manifest` alanlarını konuşmanın temel sözleşmesi kabul et.

## 2. Her Tur Öncesi Bağlam (Per-Turn Hook)
- Bootstrap sonrasında, Avenox/Beyin ile ilgili **her anlamlı assistant yanıtından önce** `avenox_turn_context` operasyonunu çalıştır (varsa `task` ve/veya `project` parametrelerini ilet).
- `avenox_turn_context` tarafından dönen `hook_skill` (`chatgpt-beyin-hook`), `recent_task_journal` ve kalıcılık yeteneklerini (`capabilities`) o turun canlı eylem ve süreklilik rehberi olarak kullan.
- Basit selamlaşma, sosyal sohbet veya Beyin dışı genel sorularda `avenox_turn_context` çağrılmaz.

## 3. Shell Komutlarını Canlı Kuyruğa Dönüştürme
- ChatGPT ortamında shell veya doğrudan `python3 beyin.py` çalıştırma imkanı yoktur; asla terminal komutu uydurma veya çalıştırmayı deneme.
- Tüm Beyin eylemlerini `chatgpt-beyin-hook` skill'indeki dönüşüm tablosuna göre canlı `public.brain_commands` kuyruk operasyonlarına (`brain_context`, `brain_task_create`, `brain_task_update`, `brain_note_create`, `brain_vault_get`, `brain_vault_update`, `brain_receipt`, `brain_sync` vb.) dönüştür.

## 4. Kuyruk ve Sonuç Takibi (Queue & Result Handling)
- Tüm operasyonlar için `public.brain_commands` tablosunu kullan. Oluşturulan command ID'yi takip et ve yalnız o command'in durumunu + `brain_responses` sonucunu oku.
- Durum `pending`, `claimed` veya `running` ise aynı assistant turunda yeniden kontrol et; kullanıcıdan “devam et” isteme ve aynı işi yeni command oluşturarak tekrar başlatma.
- `completed`, `failed` ve `conflict` terminal durumlardır.

## 5. Zorunlu ve Seçici Finalization Kontrolü
- Her anlamlı turda kullanıcıya son yanıtı göndermeden **hemen önce** finalization kontrolü yap:
  - **Kayıt Yapılacak Durumlar:** Tamamlanan iş parçası, değişen görev durumu (`brain_task_update`), yeni görev (`brain_task_create`), kalıcı mimari/kavramsal karar (`brain_note_create`), companion süreklilik kartı (`Last-Session.md`, `Threads.md`, `Journal.md`, `Kurallar.md` via `brain_vault_update`), veya iş kanıtı (`brain_receipt` with `harness: "chatgpt"`).
  - **Kayıt Yapılmayacak Durumlar:** Fikir fırtınası (brainstorming), henüz netleşmemiş taslaklar, genel soru-cevap, salt okuma turları veya kullanıcının açık "no-memory" / "kaydetme" talepleri.
- Kalıcılık gerekmiyorsa sessizce yanıtı ilet; gereksiz yazma yapma.
- Operation adı, payload alanı veya transport davranışı tahmin etme. Canlı sözleşmede bilgi yoksa uydurma.
