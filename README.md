# linksysXqmodem

Custom OpenWrt firmware builder for Linksys EA6350v3 with QModem from
[`FUjr/QModem`](https://github.com/FUjr/QModem.git).

## Cara build dari GitHub Actions

### Opsi cepat: prebuild QModem dulu

Untuk build firmware berikutnya lebih cepat, jalankan workflow **Build QModem
Packages** dulu:

1. Buka **Actions**.
2. Pilih **Build QModem Packages**.
3. Isi `openwrt_version`, `qmodem_ref`, dan `qmodem_ui`.
4. Biarkan `commit_packages=true`.

Workflow ini akan compile QModem sekali, upload artifact paket, lalu commit
paketnya ke `packages/qmodem/<versi>/<ui>/`. Setelah itu workflow firmware
bisa memakai paket prebuilt tersebut tanpa compile QModem ulang.

Di workflow firmware, opsi `qmodem_package_mode` tersedia:

- `prebuilt-or-build`: pakai prebuilt jika cocok, fallback compile jika belum ada.
- `prebuilt-only`: wajib pakai prebuilt, gagal jika belum ada.
- `build-from-source`: selalu compile QModem di run firmware itu.

### Build firmware

1. Buka tab **Actions** di repo GitHub ini.
2. Pilih workflow **Build OpenWrt EA6350v3 QModem**.
3. Klik **Run workflow**.
4. Isi `openwrt_version`, misalnya `25.12.4`.
5. Pilih UI QModem:
   - `modern`: `luci-app-qmodem-next`, pure JS UI. Ini default.
   - `legacy`: `luci-app-qmodem` plus SMS, MWAN, dan TTL add-ons.
6. Jalankan workflow, lalu ambil file firmware dari artifact hasil build.

Workflow otomatis:

- download OpenWrt SDK dan ImageBuilder resmi untuk versi yang dipilih;
- memakai paket QModem prebuilt jika tersedia, atau build paket QModem dari
  `https://github.com/FUjr/QModem.git` sebagai `.apk`;
- patch QModem untuk deteksi dan kontrol T99W175 yang lebih cocok dengan modem ini;
- membuild ulang LPAC eSIM stack tanpa dependency ModemManager, lalu memasukkan
  LuCI eSIM Manager, CLI `esim`, Telegram eSIM bot, HYFE helper dengan IMAP OTP,
  dan wrapper Ookla `speedtest`;
- build image `ipq40xx/generic` profile `linksys_ea6350v3` dengan ImageBuilder;
- upload `factory.bin`, `sysupgrade.bin`, `sha256sums`, `profiles.json`, dan `build-info.txt`.

Model SDK + ImageBuilder ini jauh lebih cepat daripada compile OpenWrt penuh
dari source, tetapi paket QModem tetap dibuild sesuai versi OpenWrt yang dipilih.

## T99W175 / DW5930e

Firmware ini memasukkan hotplug script untuk modem Foxconn T99W175/DW5930e.
Saat modem muncul sebagai `05c6:90d5` atau `05c6:9025`, script akan otomatis
melakukan binding ke driver `usb-serial` sehingga port AT tidak perlu dibuat
manual dengan `echo ... > /sys/bus/usb-serial/drivers/generic/new_id`.

Paket pendukung yang ikut dibuild:

- `kmod-usb-serial-qualcomm`
- `kmod-usb-serial-option`
- `kmod-usb-net-cdc-mbim`
- `picocom`
- `usbutils`

Pada setup yang umum, AT port T99W175 muncul sebagai `/dev/ttyUSB2`.
QModem tetap dibiarkan melakukan scan otomatis, jadi port tidak di-hardcode
ke satu nama device.

Patch QModem yang ikut diterapkan:

- deteksi model `T99W175` tetap cocok setelah nama modem dibuat lowercase;
- menu SIM Switch memakai `AT^SWITCH_SLOT`, dengan slot `0` untuk SIM fisik dan `1` untuk eSIM;
- Dial Mode membaca `AT^USBSWITCH?` secara case-insensitive dan fallback ke driver aktif, jadi MBIM tidak tampil `Unknown`;
- Quick Commands default ke bahasa Inggris saat bahasa LuCI masih `auto`;
- retry scan saat boot tidak lagi mengirim path `/sys/bus/...` sebagai nama slot modem.

## WiFi default

Saat flash pertama, firmware mengaktifkan WiFi otomatis:

- 2.4 GHz: `0x`
- 5 GHz: `0x⁵`
- Password: `1sampai10`
- Country: `ID`

## LPAC / eSIM default

Firmware ini membawa stack 0xygen-AIO:

- `lpac`
- `luci-app-lpac-manager`
- `0xygen-aio`
- rebuilt `curl`/`libcurl4` dengan IMAP/IMAPS/POP3/SMTP untuk auto OTP HYFE
- CLI `esim`
- Telegram bot eSIM management
- wrapper `speedtest`

Default LPAC disetel untuk T99W175 mode MBIM:

- APDU backend: `mbim`
- MBIM device: `/dev/cdc-wdm0`
- MBIM proxy: enabled
- MBIM skip slot mapping: enabled
- AT port: `/dev/ttyUSB2`
- modem interface untuk switch/reconnect: `1_1`
- custom ISD-R AID: `A0000005591010FFFFFFFF8900000100`

Default ini menjaga LPAC memakai `mbim-proxy` supaya akses eUICC tidak berebut
port MBIM dengan koneksi modem yang sedang aktif.
Binary proxy tersebut disediakan oleh paket `libmbim` sebagai
`/usr/libexec/mbim-proxy`; workflow build akan gagal jika `libmbim` atau
`mbim-utils` tidak masuk manifest firmware.

Firmware ini sengaja tidak memasukkan `modemmanager` atau
`luci-proto-modemmanager`. QModem menjadi satu-satunya pemilik koneksi MBIM
`/dev/cdc-wdm0` dan `wwan0`, sedangkan LPAC hanya memakai akses MBIM proxy
untuk manajemen eSIM.

## Catatan penting EA6350v3

Pada OpenWrt baru, EA6350v3 memakai kernel partition size yang lebih besar.
Sebelum memakai firmware hasil build versi baru, pastikan environment U-Boot
router sudah sesuai dengan instruksi OpenWrt untuk EA6350v3. Jika belum,
sysupgrade bisa gagal atau firmware tidak boot.

Peringatan dari OpenWrt untuk target ini menyebut perintah:

```sh
fw_setenv kernsize 500000
```

Alternatif dari U-Boot serial console:

```sh
setenv kernsize 500000
saveenv
```

Setelah perubahan ukuran kernel, gunakan image yang sesuai dan ikuti prosedur
upgrade OpenWrt untuk Linksys EA6350v3.
