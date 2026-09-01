# LIVI yamaları

Bu klasördeki yamalar [LIVI](https://github.com/f-io/LIVI) kaynak ağacına uygulanır.
Uygulamak için LIVI'yi klonlayıp yamayı uygulayın, sonra kendiniz derleyin.

## 0001-add-turkish-translation.patch

LIVI arayüzüne Türkçe dil desteği ekler.

**Kapsam:** 266 anahtarın tamamı çevrildi. `en.json` ile birebir eşleşiyor — eksik veya
fazla anahtar yok, `{{name}}` gibi tüm interpolasyon yer tutucuları korundu.

**Değişen dosyalar:**

| Dosya | Değişiklik |
|---|---|
| `src/renderer/src/locales/tr.json` | Yeni — tam çeviri |
| `src/renderer/src/i18n.ts` | `tr` kaydı ve `supportedLngs`'e eklenmesi |
| `src/renderer/src/routes/schemas/generalSchema.ts` | Ayarlardaki dil listesine "Turkish" |
| `locales/{en,de,fr,ua}.json` | `settings.turkish` etiketi (her dilde kendi karşılığı) |

**Uygulama:**

```bash
git clone https://github.com/f-io/LIVI.git
cd LIVI
git apply /yol/patches/0001-add-turkish-translation.patch
```

**Arayüzü Mac'te önizleme** (Pi gerekmez, native modüller derlenmeden çalışır):

```bash
pnpm install
pnpm dev
```

Ayarlar → General → Language → Turkish.

**Cihaza almak için** AppImage derlemesi gerekiyor; bu Linux ARM64 + Node 24 + Rust +
GStreamer dev + meson/wlroots istiyor. En pratik yol LIVI'yi fork'layıp GitHub Actions'a
derletmek — proje zaten AppImage'ları CI ile üretiyor.

## 0004-headless-status-ui.patch

Headless sürüme (0002'nin üstüne uygulanır) LVGL bekleme ekranı bağlantısını
ekler: yeni `src/main/headless/statusUi.ts` süreci yönetir, `index.ts`'teki
event sink olayları ona iletir. Ekranı çizen C programı bu repoda —
`headless/statusui/` — ve tamamen opsiyoneldir: ikili pakette yoksa yama
hiçbir davranış değiştirmez. Detay: `headless/statusui/README.md`.

## 0005-headless-input-bridge.patch

Headless sürüme (0004'ün üstüne) USB girdi köprüsü ekler:
`src/main/headless/inputBridge.ts` `/dev/input/event*` cihazlarını okur ve
olayları shim'in `ipcMain`'i üzerinden LIVI'nin kendi `projection-touch` /
`projection-command` dinleyicilerine verir — sıfır LIVI değişikliği.

Eşleme donanımda ölçülerek seçildi (Pi 3B+, Android Auto): dokunma çalışıyor
ama imleç çizilemediği için körlemesine kalıyor, D-Pad tuşları telefona ulaşıp
hiçbir şey yapmıyor, **rotary tıkları ise odak halkasını gezdiriyor** — yeter ki
ünite dokunmatik olduğunu duyurmasın (0006). Bu yüzden gezinme tek boyutlu:
fare sağa/aşağı ve tekerlek odağı ileri, sola/yukarı geri taşır; sol tık seçer,
sağ tık geri, orta tık ana ekran. `LIVI_INPUT_MODE=touch` mutlak dokunmaya
döner, `LIVI_INPUT_BRIDGE=0` köprüyü kapatır.

Not: `SendCommand` komut ADI bekler (`CommandMapping[value]`); sayı verilirse
ters çevrilip sessizce düşer.

## 0006-aa-controller-input-mode.patch

Android Auto'ya "dokunmatik ekranım var" demeyi `LIVI_AA_TOUCHSCREEN=0` ile
kapatılabilir yapar (varsayılan davranış değişmez). Kapatıldığında telefon
üniteyi döner kumandalı araç gibi görür ve **odak halkasını kendisi çizer** —
imleç çizilemeyen headless kurulumda ekranda gezinmenin tek görünür yolu budur.
Pi 3B+'ta ölçüldü: dokunmatik duyurulurken D-Pad tuşları telefona ulaşıp hiçbir
şey yapmıyor, odak halkası hiç çıkmıyor.

## Terminoloji notları

Otomotiv arayüzünde yerleşik olmayan bazı terimler için yapılan seçimler:

| İngilizce | Türkçe | Not |
|---|---|---|
| Head Unit | Ana Ünite | |
| Cluster | Gösterge Paneli | Araç gösterge ekranı |
| Knob | Düğme | Döner kumanda |
| Hook Switch | Ahize Tuşu | Telefon aç/kapa |
| Safe Area / View Area | Güvenli Alan / Görüntü Alanı | |
| Dongle, FPS, DPI, DOP, AGC, RTK | değiştirilmedi | Yerleşik teknik kısaltmalar |
| Nightly | değiştirilmedi | Sürüm kanalı adı |

## Upstream

Bu yama LIVI projesine pull request olarak gönderilebilir. Çeviri eksiksiz ve mevcut
dillerin yapısına uyuyor, ek bağımlılık getirmiyor.
