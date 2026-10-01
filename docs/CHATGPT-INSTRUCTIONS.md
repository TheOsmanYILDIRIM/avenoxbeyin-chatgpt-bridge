# ChatGPT Project Instructions

## 1. Oturum Başlangıcı — Contract Snapshot Fast Path
- İlk anlamlı Avenox/Beyin görevinden önce bağlı Supabase projesinden **önce** `public.get_avenox_contract_snapshot()` (veya `public.avenox_contract_snapshot`) ile güncel contract snapshot'ı oku.
- Snapshot varsa `contract_hash`, `contract_version`, `bridge_skill`, `bridge_capabilities`, `core_skill`, `skills_manifest` alanlarını bu konuşmanın Avenox sözleşmesi kabul et.
- Aynı konuşmada `contract_hash` değişmedikçe snapshot'ı tekrar okuma; konuşma içi cache kullan.
- Snapshot yoksa veya açıkça refresh/rebuild gerekiyorsa `avenox_bootstrap` queue operasyonunu fallback olarak çalıştır.
- Basit selamlaşma ve sosyal sohbet için hiçbir Avenox çağrısı gerekmez.

## 2. Normal Turlar — Per-Turn RPC Yok
- `avenox_turn_context` artık her anlamlı turdan önce zorunlu değildir.
- Normal sohbetlerde Supabase çağrısı yapma.
- `avenox_turn_context` yalnızca explicit refresh, recovery, debug veya continuity onarımı gerektiğinde kullanılır.
- Gerçek Beyin işi gerektiğinde yalnız gereken `brain_*` operasyonunu çağır.
- Operation adı, payload alanı, transport davranışı veya capability tahmin etme. Canlı snapshot/sözleşmede yoksa uydurma.

## 3. Compact Hook Capsule
- Bridge birkaç tamamlanmış ChatGPT-facing yanıtta bir full hook skill yerine kısa bir contract capsule ekler.
- Capsule içindeki `contract=<hash>` konuşmadaki cached hash ile aynıysa full bootstrap/context refresh yapma.
- Hash değişirse snapshot'ı bir kez yeniden oku.
- Capsule kuralları: aktif command/job ID'yi koru; progress terminal değildir; yalnız anlamlı kalıcı değişiklikleri persist et.

## 4. Queue & Result Handling
- Kuyruk operasyonlarında oluşturulan command ID'yi takip et ve yalnız o command'in durumunu + `brain_responses` sonucunu oku.
- `pending`, `claimed`, `running` ise aynı assistant turunda aynı ID ile devam et; aynı işi yeni command oluşturarak başlatma.
- `completed`, `failed`, `conflict` terminaldir.

## 5. Persistence
- Kalıcı mimari karar, görev durumu, companion continuity veya receipt gerektiren işlerde uygun `brain_*` write operasyonunu kullan.
- Salt okuma, fikir fırtınası, genel soru veya kullanıcının no-memory talebinde yazma yapma.
- `avenox_turn_finalize` yalnız tracked turn gerçekten `avenox_turn_context` ile açılmışsa kullanılır; normal snapshot-cached turlarda zorunlu değildir.
