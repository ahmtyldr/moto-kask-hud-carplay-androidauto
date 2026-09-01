# livi-statusui — headless için LVGL bekleme ekranı

Telefon bağlı değilken ekranda dönen bir spinner, "Cihaz bekleniyor" başlığı ve
tek satırlık durum mesajı gösterir. Chromium'suz, compositor'suz — doğrudan
KMS/DRM'e çizer; derlenmiş hali birkaç yüz KB, boştayken CPU kullanımı ~sıfır.

## Nasıl çalışıyor

KMS'te ekranın tek sahibi olabilir. Bu yüzden yaşam döngüsü Node tarafından
yönetilir (`patches/0004-headless-status-ui.patch` → `statusUi.ts`):

```
açılış        → Node bu programı başlatır, ekran "Cihaz bekleniyor"
video başladı → Node SIGTERM yollar; çıkış DRM master'ı bırakır, kmssink devralır
telefon koptu → Node yeniden başlatır
```

Olay eşlemesi kanal adlarına regex ile bakar ve LIVI sürümüne göre değişebilir.
İlk gerçek donanım testinde `LIVI_HEADLESS_VERBOSE=1` ile çalıştırıp `[event]`
satırlarındaki gerçek kanal adlarına göre şu env'leri ayarlayın:

| Env | Varsayılan davranış |
|---|---|
| `LIVI_STATUSUI_HIDE_ON` | video/oturum **başlarken** ekranı kapat |
| `LIVI_STATUSUI_SHOW_ON` | oturum **biterken** geri getir |
| `LIVI_STATUSUI_RELAY_ON` | BT eşleşme / dongle / hotspot olaylarını mesaj satırına bas |
| `LIVI_STATUSUI_BIN` | ikili yolu (varsayılan `/opt/livi/statusui/livi-statusui`) |
| `LIVI_STATUSUI=0` | tamamen kapat |
| `LIVI_DRM_DEVICE` | DRM kartını elle seç (varsayılan: bağlı konnektörü olan kart taranır) |

## stdin protokolü

Node süreci çocuğun stdin'ine satır yazar: `title <metin>`, `msg <metin>`,
`quit`. stdin EOF olursa (Node öldüyse) program kendini kapatır — ekran,
kendisini öldürecek sürecin yokluğunda asla sahipsiz kalmaz.

## Derleme

Headless bundle'ı derleyen arm64 konteynerde:

```bash
apt-get install -y cmake build-essential libdrm-dev pkg-config
cd headless/statusui
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Çıkan `build/livi-statusui` ikilisini pakete koyun:

```
dist-headless/
└── statusui/livi-statusui
```

`install.sh` bu dosya varsa çalıştırılabilir yapar; yoksa hiçbir şey değişmez —
bekleme ekranı tamamen opsiyoneldir, yokluğu servisi etkilemez.

## Türkçe karakterler

LVGL'in gömülü Montserrat fontları yalnızca ASCII kapsar; bu yüzden varsayılan
metinler bilerek ASCII ("Cihaz bekleniyor"). "aranıyor/bağlantı" gibi ı/ğ/ş
içeren metin göstermek için `lv_font_conv` ile tam kapsamlı font üretin:

```bash
npx lv_font_conv --font Montserrat-Medium.ttf --size 28 --bpp 4 \
  --range 0x20-0x7F --symbols ıİğĞşŞçÇöÖüÜ \
  --format lvgl -o font_tr_28.c
```

Üretilen `font_tr_28.c`'yi `CMakeLists.txt`'e ekleyip `main.c`'de
`&lv_font_montserrat_28` yerine `&font_tr_28` kullanın.

## Durum

Kod yazıldı, henüz derlenmedi/donanımda doğrulanmadı — headless sürümün
kendisiyle aynı doğrulama aşamasında. İlk testte en olası pürüzler: LVGL sürüm
API'sinde küçük imza farkları (v9.2.2'ye sabitlendi) ve DRM izinleri (`livi`
kullanıcısı `video` grubunda olmalı; `install.sh` bunu zaten yapıyor).
