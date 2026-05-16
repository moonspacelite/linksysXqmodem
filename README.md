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

- clone OpenWrt sesuai tag `v<openwrt_version>`;
- menambahkan feed `https://github.com/FUjr/QModem.git`;
- build target `ipq40xx/generic` untuk `linksys_ea6350v3`;
- upload `factory.bin`, `sysupgrade.bin`, `sha256sums`, dan `config.seed`.

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
