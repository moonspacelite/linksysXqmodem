# linksysXqmodem

Custom OpenWrt firmware builder for Linksys EA6350v3 with QModem from
[`FUjr/QModem`](https://github.com/FUjr/QModem.git).

## Cara build dari GitHub Actions

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
- build paket QModem dari `https://github.com/FUjr/QModem.git` sebagai `.apk`;
- patch deteksi model `T99W175` agar cocok dengan scan lowercase QModem;
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
