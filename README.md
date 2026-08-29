# moto-kask-hud-carplay-androidauto

Motosiklet için CarPlay ve Android Auto çalıştıran, görüntüyü AR gözlük üzerinden HUD olarak
veren bir head unit projesi. Çekirdek yazılım olarak [LIVI](https://github.com/f-io/LIVI)
kullanılıyor; bu repo kurulum otomasyonunu, cihaza özgü düzeltmeleri ve donanım notlarını
tutuyor.

## Durum

| Aşama | Durum |
|---|---|
| Raspberry Pi 3B+ üzerinde LIVI | ✅ Çalışıyor (geçici video düzeltmesiyle) |
| Kablosuz Android Auto | ✅ Çalışıyor — 5 GHz AP, kanal 36 |
| Kablosuz CarPlay | ⏳ Carlinkit dongle bekleniyor |
| Türkçe arayüz | ✅ Yama hazır ([patches/](patches/)) |
| CM4'e geçiş | ⏳ Planlandı |
| AR gözlük ile HUD | ⏳ Planlandı |

## Neden bu repo var

LIVI, Raspberry Pi 3'ü resmen desteklemiyor ve gerekçe olarak OpenGL ES 3.x ihtiyacını
gösteriyor. İnceleme sonucu bunun doğru teşhis olmadığı ortaya çıktı: GPU yeterli, engel
GStreamer hattındaki tek bir eksik eleman. Tam analiz ve çözüm:

**→ [docs/pi3-video-fix.md](docs/pi3-video-fix.md)**

Özet: LIVI renk dönüştürücüyü (`videoconvert`) yalnızca yazılım çözücü seçtiğinde ekliyor.
Pi 4/5'te donanım çözücü DMABuf verdiği için buna gerek yok; Pi 3'te çözücü YUV'u normal
bellekte veriyor ve `waylandsink` orada sadece RGB kabul ediyor → `not-negotiated (-4)`,
hiç kare üretilmiyor.

## Türkçe dil desteği

LIVI'ye Türkçe arayüz ekleyen yama `patches/` altında — 266 anahtarın tamamı çevrildi.
Uygulama ve derleme adımları için [patches/README.md](patches/README.md).

## Kurulum

### 1. Kart hazırla

Raspberry Pi OS Trixie (arm64 Lite) imajını SD karta yaz:

```bash
sudo diskutil unmountDisk force /dev/diskN          # macOS
sudo dd if=raspios.img of=/dev/rdiskN bs=4m status=progress
```

### 2. Boot bölümünü yapılandır

```bash
cp boot/firstrun.sh              /Volumes/bootfs/
cp boot/livi-setup.env.example   /Volumes/bootfs/livi-setup.env
touch /Volumes/bootfs/ssh
```

`livi-setup.env` dosyasını doldurun (Wi-Fi bilgileri ve parola hash'i). Hash için:

```bash
openssl passwd -6 'parolaniz'
```

`cmdline.txt` sonuna ekleyin (tek satır kalmalı):

```
systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
```

`config.txt` sonuna:

```ini
[pi3]
gpu_mem=128
[all]
```

### 3. Aç

İlk açılış hazırlık yapıp yeniden başlar, ardından LIVI otomatik kurulur (15-25 dk) ve
kiosk modda açılır. Günlükler: `/boot/firmware/firstrun.log` ve `/boot/firmware/livi-install.log`.

### 4. Pi 3 kullanıyorsanız video düzeltmesi

```bash
sudo mkdir -p /etc/systemd/system/livi-kiosk.service.d
sudo cp systemd/livi-pi3.conf /etc/systemd/system/livi-kiosk.service.d/
sudo systemctl daemon-reload
sudo systemctl stop livi-kiosk; sudo systemctl stop getty@tty1
sudo systemctl start livi-kiosk
```

CM4/Pi 4/Pi 5'te bu adım **gerekmez ve yapılmamalıdır** — orada donanım çözme zaten çalışıyor.

## Donanım

### Şu anki (prototip)

Raspberry Pi 3B+, 64 GB SD kart, HDMI ekran, 5V/2.5A adaptör.

Bilinen sınırlar: yazılımda HEVC çözme yüzünden yoğun sahnelerde donma; 60 °C üstünde
saat 1400→1200 MHz düşüyor. Soğutucu şart.

### Hedef

| Parça | Seçim | Not |
|---|---|---|
| Kart | CM4 4 GB / 32 GB eMMC / **Wireless** | LIVI resmen destekliyor, donanım H.264 çözücü var |
| Taşıyıcı | Waveshare CM4-NANO-B | 56×41 mm, mini HDMI, 1× USB-A, 3.5 mm ses |
| HUD | AR gözlük (XREAL Air 2 / Rokid / Viture) | HDMI→USB-C adaptörle CM4'e bağlanır |
| CarPlay | Carlinkit dongle | LIVI `VID 0x1314`, `PID 0x1520/0x1521` tanıyor |
| Kontrol | Gidon üstü Bluetooth keypad | LIVI'nin D-Pad/tuş atama desteği |

**Neden dongle, MFi çipi değil:** Apple MFi yardımcı işlemcisinin datasheet'i NDA altında ve
hazır breakout kartı satılmıyor. Dongle'ın içinde lisanslı çip zaten var. Native MFi
(`carPlayMfiI2cBus=2`, SDA=GPIO19, SCL=GPIO26, güç=GPIO21) ileride USB portunu boşaltmak
için değerlendirilebilir.

**Güvenlik notu:** Kaska sert cisim monte etmek ECE 22.06 sertifikasyonunu geçersiz kılar ve
kazada boyna binen kuvveti artırır. Bu proje kaska hiçbir şey monte etmiyor — hesaplama
üstte/motorda, görüntü kask altına takılan AR gözlükte.

## Lisans

Bu repodaki scriptler ve dokümanlar. LIVI'nin kendisi ayrı bir proje ve GPL-3.0-or-later
lisanslı — bu repo LIVI'yi içermiyor, sadece kurar ve yapılandırır.
