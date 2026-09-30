---
name: chatgpt-beyin-hook
description: ChatGPT Web/Android için canlı Avenox Beyin hook ve süreklilik sözleşmesi. Shell komutlarını canlı Bridge kuyruk operasyonlarına dönüştürür, ne zaman kayıt yapılacağını/yapılmayacağını ve son yanıttan önce zorunlu-seçici finalization kontrollerini tanımlar.
---

# Avenox Beyin ChatGPT Hook ve Süreklilik Sözleşmesi

Bu skill, ChatGPT Web ve Android ortamlarında Avenox Beyin ile çalışırken geçerli olan canlı turn-hook ve süreklilik kurallarını tanımlar.

## Temel Çalışma İlkesi

1. **Shell Yoktur:** ChatGPT ortamında yerel shell erişimi veya doğrudan `python3 beyin.py` çalıştırma imkanı yoktur. Beyin ile ilgili tüm eylemler Supabase `public.brain_commands` kuyruğundaki canlı Bridge operasyonları üzerinden yürütülür.
2. **Bootstrap Tek Seferliktir:** `avenox_bootstrap` yalnızca oturum/konuşma başlangıcındaki ilk anlamlı Avenox işinde bir kez çağrılır. Her turda tekrarlanmaz.
3. **Tur Bağlamı (Turn Context):** Oturum başladıktan sonra, her anlamlı Avenox/Beyin turu öncesinde `avenox_turn_context` çağrılır. Bu operasyon hafif siklet olup canlı hook sözleşmesini, son görev günlüğünü (`recent_task_journal`) ve kalıcılık için gerekli canlı yetenek alt kümesini döner.
4. **Basit Sohbet İstisnası:** Basit selamlaşma, sosyal sohbet veya Beyin ile ilgisiz turlarda `avenox_turn_context` çağrılmaz.

---

## Shell → Canlı Kuyruk Operasyon Dönüşümü

Beyin dokümantasyonunda geçen shell komutlarını asla doğrudan çalıştırmayı deneme; aşağıdaki canlı Bridge operasyonlarına dönüştür:

| Klasik Beyin Shell Komutu | Canlı Bridge Kuyruk Operasyonu | Payload Şeması & Örnek |
|---|---|---|
| `python3 beyin.py context "sorgu"` | `brain_context` | `{"query": "sorgu", "project": "proje-adi", "limit": 10}` |
| `python3 beyin.py task-create --file ...` | `brain_task_create` | `{"source": "tasks/gorev-adi.md", "text": "Açıklama", "metadata": {"id": "gorev-id", "title": "Başlık", "kind": "task", "revision": 1, "status": "active", "owner": "sorumlu", "project": "proje"}}` |
| `python3 beyin.py task-update --file ...` | `brain_task_update` | `{"id": "gorev-id", "expected_revision": 1, "changes": {"status": "done"}}` |
| `python3 beyin.py note-create --file ...` | `brain_note_create` | `{"source": "knowledge/karar.md", "text": "İçerik", "metadata": {"kind": "fact", "project": "proje", "visibility": "internal"}}` |
| `python3 beyin.py receipt --file ... --harness ...` | `brain_receipt` | `{"event_id": "olay-id", "summary": "İş özeti", "refs": ["kaynak1.md"], "harness": "chatgpt", "session": "oturum"}` |
| `python3 beyin.py sync` | `brain_sync` | `{}` |
| `python3 beyin.py history KAYIT_ID` | `brain_history` | `{"id": "kayit-id"}` |
| `python3 beyin.py companion-compact` | `brain_companion_compact` | `{"dry_run": false}` |
| Companion / Vault dosya okuma | `brain_vault_get` | `{"source": "Last-Session.md"}` (veya `Threads.md`, `Journal.md`, `Core.md`, `Kurallar.md`) |
| Bounded satır aralığı okuma | `brain_vault_read_range` | `{"source": "Threads.md", "start_line": 1, "end_line": 50}` |
| Dosya keşfi ve arama | `brain_vault_find` / `brain_vault_search` | `{"query": "arama"}` |
| Companion / Vault CAS yazma | `brain_vault_update` | `{"source": "Last-Session.md", "expected_sha256": "...", "content": "..."}` |

---

## Kalıcılık ve Süreklilik Politikası (Persistence Policy)

ChatGPT hangi durumlarda Beyin'e kayıt yapacağını ve hangi durumlarda **kesinlikle kayıt yapmayacağını** aşağıdaki kurallara göre belirler:

### 1. Ne Zaman Kayıt YAPILMAZ (Do NOT Persist)
- **Basit Selamlaşma / Sosyal Sohbet:** "Merhaba", "Nasılsın", "Teşekkürler" gibi diyaloglar.
- **Genel Soru-Cevap:** Beyin vault'u ile ilgisi olmayan genel kültür, dilbilgisi veya genel kodlama soruları.
- **Fikir Fırtınası (Brainstorming):** Henüz netleşmemiş, karara bağlanmamış veya eylem maddesi haline gelmemiş geçici serbest fikir alışverişleri.
- **Salt Okuma / İnceleme:** Vault içinde sadece arama veya okuma yapılan ve yeni bir çıktı/karar üretilmeyen durumlar.
- **Kullanıcının Açık Kapsam Tercihi:** Kullanıcı açıkça "kaydetme", "hafızaya yazma", "no-memory" veya "no-tools" istediğinde.

### 2. Ne Zaman Kayıt YAPILIR (DO Persist)
- **Görev Durumu Değişiklikleri:** Bir görev tamamlandığında, engellendiğinde (`blocked`), yeni aşamaya geçtiğinde (`brain_task_update`) veya yeni somut görev açıldığında (`brain_task_create`).
- **Kalıcı Kararlar ve Bilgiler:** Proje veya sistem için kalıcı bir mimari karar, kural veya bilgi netleştiğinde (`brain_note_create` veya `knowledge/` altındaki ilgili kaynaklar).
- **Kullanıcı Kural ve Tercihleri:** Kullanıcı açıkça kalıcı bir çalışma kuralı, biçim tercihi veya kimlik yönlendirmesi verdiğinde (`Kurallar.md` veya `Core.md` via `brain_vault_update`).
- **Companion Süreklilik Devir Kartı (`Last-Session.md`):** Anlamlı bir iş parçası tamamlandığında, devir kartı baştan yazılarak yerinde güncellenir: ne yapıldı, neden o karar verildi, ne açık kaldı, sonraki somut adım ve kaynak referansları. Eski kayıt alta eklenmez.
- **Açık Konular (`Threads.md`):** Aktif iş maddesinin durumu, sahibi veya sonraki adımı yerinde güncellenir; biten konu kapalılar bölümüne aktarılır.
- **Ortak Öğrenim (`Journal.md`):** Önemli bir ortak çıkarım veya metodolojik öğrenim olduğunda kısa tarihli gözlem eklenir.
- **İş Kanıtı (`brain_receipt`):** Kaynak-bağlantılı tamamlanan bir çalışma sonrasında `harness: "chatgpt"` ile receipt oluşturulur.

---

## İki Aşamalı Tur Yaşam Döngüsü (Two-Phase Turn Lifecycle)

Her anlamlı Avenox Beyin turu iki aşamalı (two-phase) olarak yürütülür:

### Faz 1: Başlangıç (Turn Context)
1. Anlamlı turlarda ilk adım olarak `avenox_turn_context` çağrılır (`{"task": "...", "project": "..."}`).
2. Bu çağrı Supabase üzerinde açık bir tur (`chatgpt_turns`) kaydı oluşturur ve benzersiz bir `turn_id` döner.
3. Eğer önceki bir tur sonlandırılmadan açık kalmışsa (`previous_unfinalized_turn`), güçlü bir uyarı (`WARNING: UNFINALIZED PREVIOUS TURN`) döner. Bu durumda önceki turun hafıza/receipt kayıtlarının tamamlandığından emin olun veya gerekirse toparlayın.
4. Yanıtın sonundaki **FINALIZATION GUARD** hatırlatıcısına dikkat edin.

### Faz 2: Sonlandırma (Turn Finalize)
Kullanıcıya nihai yanıt verilmeden **hemen önce**, `avenox_turn_finalize` operasyonu çağrılmalıdır:

```json
{
  "turn_id": "<turn_id>",
  "state_changed": true,
  "summary": "Last-Session.md ve Threads.md güncellendi, receipt oluşturuldu.",
  "refs": ["Last-Session.md", "Threads.md"]
}
```

- **`state_changed: true`**: Tur sırasında bir not, görev, companion dosyası (`Last-Session.md`, `Threads.md`, `Journal.md`, `Kurallar.md`) veya `brain_receipt` yazıldıysa `true` yapılmalı ve güncellenen/yazılan dosyalar `refs` dizisinde **en az bir kaynak ile** listelenmelidir (boş liste reddedilir).
- **`state_changed: false`**: Tur salt okuma, arama veya genel yanıt amaçlıysa ve hiçbir hafıza/durum yazımı gerekmediyse `false` yapılmalı ve `refs: []` boş dizi olarak geçilmelidir.
- `avenox_turn_finalize` çağrısı idempotenttir; aynı tur için tekrar çağrılsa bile güvenle tamamlanır.

---

## Zorunlu ve Seçici Finalization Sözleşmesi (Finalization Contract)

ChatGPT, her anlamlı Avenox turunda kullanıcıya nihai yanıtını göndermeden **hemen önce** şu sonlandırma kontrolünü zorunlu olarak gerçekleştirir:

1. **Değerlendirme:** Bu turda tamamlanan bir iş, durum güncellemesi gereken bir görev, kalıcı hale gelen bir karar veya güncellenecek companion süreklilik dosyası (`Last-Session.md`, `Threads.md`, `Journal.md`, `Kurallar.md`) var mı?
2. **Kalıcılık Gerekliyse:**
   - İlgili dosya güncellenecekse önce `brain_vault_get` ile güncel içeriği ve `sha256` değerini oku.
   - Gerekli içerik düzenlemesini yap ve `brain_vault_update` ile CAS güvenliğinde yaz.
   - Görev güncellemeleri için `brain_task_update` kullan (görev dosyalarını asla vault_update ile doğrudan yazma).
   - Tamamlanan iş parçası için `brain_receipt` (harness: "chatgpt") kaydı oluştur.
   - Kuyruk operasyonlarının `completed` sonucunu doğrula.
   - **`avenox_turn_finalize`** çağrısını `state_changed: true` ve `refs: ["..."]` ile gerçekleştir.
3. **Kalıcılık Gerekmiyorsa:**
   - **`avenox_turn_finalize`** çağrısını `state_changed: false` ve `refs: []` ile gerçekleştir.
4. **Çakışma (`conflict`) Yönetimi:**
   - `brain_vault_update` veya `brain_task_update` conflict hatası dönerse, güncel içeriği/revizyonu tekrar oku ve değişikliği güncel durum üzerine uygulayarak yeniden dene.
