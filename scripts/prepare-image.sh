#!/usr/bin/env bash
# Customizes the devmfc Ubuntu image for the Xiaomi TV Box S 2nd Gen (jaws) before flashing:
#   1. adds the MediaTek MT7663 WiFi firmware (missing from the stock image)
#   2. writes the WiFi credentials from .env (PSK stored hashed, never in plaintext)
#   3. enables wpa_supplicant@wlan0 so WiFi comes up without a keyboard
#   4. installs an SSH public key for root and sets the hostname
#   5. installs overlay/ (jarvis-diag: writes WiFi diagnostics to /boot/diag every boot)
#   6. installs libgpiod tools + jarvis-wifi-power (power-cycles the WiFi chip on GPIOX_6)
#   7. builds a jaws DTB from the s905x4 generic one with the single USB port forced to host
#      (generic dr_mode="otg" makes the port switch to Device Mode -> rootfs on USB never found),
#      and selects it via box=xiaomi_jaws in boot.config
# Usage: ./scripts/prepare-image.sh <image.img>
set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly IMG="${1:?Usage: $0 <image.img>}"
readonly FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek"
readonly FW_FILES=(mt7663pr2h.bin mt7663_n9_v3.bin mt7663pr2h_rebb.bin mt7663_n9_rebb.bin)
readonly FW_DIR="${REPO_DIR}/firmware/mediatek"
readonly SSH_KEY="${HOME}/.ssh/xiaomibox_ed25519"
readonly PKG_DIR="${REPO_DIR}/packages"
readonly PKG_URL="https://ports.ubuntu.com/ubuntu-ports/pool/universe/libg/libgpiod"
# SHA512 from the Ubuntu 26.10 (stonking) universe/binary-arm64 Packages index, checked 2026-11-02.
readonly PKG_FILES=(gpiod_2.2.5-1_arm64.deb libgpiod3_2.2.5-1_arm64.deb)
readonly PKG_SHA512=(
  bd2d6f5b2ffea947380589c8fa79947555d35acc78340e924221d719a6903c6e21c779d975f6fe871e2d340f52ab3bd57b9b60bb6500a9d00f450aa5f291a5ed
  5e1461e345c7d8da4e2591ee3cec611e89c1a1e2d14accf44bf8dd3ca1588a673decbbb89279cce13e7e3a78eb87e83ff56c05a2c7c36d3e6fe12bc71ff808d8
)
# SHA256 of linux-firmware mediatek files as first downloaded 2026-11-01 (git.kernel.org, HTTPS).
readonly FW_SHA256=(
  534f2152f9b0f48dfcec9c1727b0bab9a3727a655d76d5ec818cc39a55602336
  d8b8488f37f65e41ded9a911950afb000d236b36e5aa94ad9650ad0c3a86fd45
  e812442fd631ecbea7d2898c3168cb5780377378a0eed74c14fe8d8057fe547c
  5e1a65036ccf9f53a6f69d9d8f75a07f546f9a7cec83ca89f24907925c54f079
)
readonly BOX_CONFIG="xiaomi_jaws"
readonly BASE_DTB="meson-sc2-ah212-generic.dtb"
readonly JAWS_DTB="meson-sc2-xiaomi-jaws.dtb"

die() { echo "ERROR: $*" >&2; exit 1; }

# fetch_verified <url> <dest> <shasum-algo> <expected-hex>: downloads if missing, always verifies,
# deletes the file and aborts on mismatch (covers cached files too).
fetch_verified() {
  local url="$1" dest="$2" algo="$3" want="$4" got
  [[ -s "${dest}" ]] || curl -sfL --proto '=https' -o "${dest}" "${url}" || die "download failed: ${url}"
  got="$(shasum -a "${algo}" "${dest}" | cut -d' ' -f1)"
  [[ "${got}" == "${want}" ]] || { rm -f "${dest}"; die "checksum mismatch for ${dest}"; }
}

[[ -f "${IMG}" ]] || die "image not found: ${IMG}"
[[ -f "${REPO_DIR}/.env" ]] || die "missing .env (copy .env.example and fill WIFI_SSID / WIFI_PSK)"
# shellcheck disable=SC1091
source "${REPO_DIR}/.env"
[[ -n "${WIFI_SSID:-}" && -n "${WIFI_PSK:-}" ]] || die "WIFI_SSID and WIFI_PSK must be set in .env"
(( ${#WIFI_PSK} >= 8 && ${#WIFI_PSK} <= 63 )) || die "WIFI_PSK must be 8..63 characters"
readonly HOSTNAME_BOX="${BOX_HOSTNAME:-jarvis}"
command -v docker >/dev/null || die "docker is required to mount the ext4 rootfs"

mkdir -p "${FW_DIR}"
for i in "${!FW_FILES[@]}"; do
  fetch_verified "${FW_URL}/${FW_FILES[i]}" "${FW_DIR}/${FW_FILES[i]}" 256 "${FW_SHA256[i]}"
done

mkdir -p "${PKG_DIR}"
rm -f "${PKG_DIR}"/*build1*.deb
for i in "${!PKG_FILES[@]}"; do
  fetch_verified "${PKG_URL}/${PKG_FILES[i]}" "${PKG_DIR}/${PKG_FILES[i]}" 512 "${PKG_SHA512[i]}"
done

[[ -f "${SSH_KEY}" ]] || ssh-keygen -q -t ed25519 -N "" -C "xiaomibox" -f "${SSH_KEY}"

# WPA-PSK = PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32), same as wpa_passphrase.
PSK_HEX="$(WIFI_SSID="${WIFI_SSID}" WIFI_PSK="${WIFI_PSK}" python3 -I -c '
import hashlib, os
print(hashlib.pbkdf2_hmac("sha1", os.environ["WIFI_PSK"].encode(), os.environ["WIFI_SSID"].encode(), 4096, 32).hex())')"
readonly PSK_HEX

IMG_DIR="$(cd "$(dirname "${IMG}")" && pwd)"
IMG_NAME="$(basename "${IMG}")"

# Partition offsets (bytes) read from the image's MBR, not hardcoded.
read -r BOOT_OFF ROOT_OFF < <(python3 -I - "${IMG}" <<'EOF'
import struct, sys
mbr = open(sys.argv[1], "rb").read(512)
starts = [struct.unpack_from("<I", mbr, 446 + 16 * i + 8)[0] * 512 for i in range(2)]
print(*starts)
EOF
)

docker run --rm --privileged \
  -v "${IMG_DIR}:/img" -v "${FW_DIR}:/fw:ro" -v "${SSH_KEY}.pub:/key.pub:ro" \
  -v "${REPO_DIR}/overlay:/overlay:ro" -v "${PKG_DIR}:/pkg:ro" -v "${REPO_DIR}/dashboard:/dashboard:ro" \
  -e IMG_NAME="${IMG_NAME}" -e BOOT_OFF="${BOOT_OFF}" -e ROOT_OFF="${ROOT_OFF}" \
  -e SSID="${WIFI_SSID}" -e PSK_HEX="${PSK_HEX}" -e HOSTNAME_BOX="${HOSTNAME_BOX}" -e BOX_CONFIG="${BOX_CONFIG}" \
  -e BASE_DTB="${BASE_DTB}" -e JAWS_DTB="${JAWS_DTB}" \
  alpine:3.20 sh -euc '
    mkdir -p /r /b
    mount -o loop,offset="${ROOT_OFF}" "/img/${IMG_NAME}" /r
    mount -o loop,offset="${BOOT_OFF}" "/img/${IMG_NAME}" /b
    trap "umount /r /b" EXIT

    install -d -m 755 /r/lib/firmware/mediatek
    install -m 644 /fw/*.bin /r/lib/firmware/mediatek/

    printf "ctrl_interface=/run/wpa_supplicant\nupdate_config=1\ncountry=US\n\nnetwork={\n\tssid=\"%s\"\n\tpsk=%s\n}\n" \
      "${SSID}" "${PSK_HEX}" > /r/root/wpa_supplicant.conf
    chmod 600 /r/root/wpa_supplicant.conf
    ln -sfn /usr/lib/systemd/system/wpa_supplicant@.service \
      /r/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service

    install -D -o 0 -g 0 -m 755 /overlay/usr/local/sbin/jarvis-diag /r/usr/local/sbin/jarvis-diag
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/system/jarvis-diag.service \
      /r/etc/systemd/system/jarvis-diag.service
    rm -f /r/etc/systemd/system/multi-user.target.wants/jarvis-diag.service
    mkdir -p /r/etc/systemd/system/timers.target.wants
    for t in jarvis-diag jarvis-wifi-watchdog; do
      install -D -o 0 -g 0 -m 644 "/overlay/etc/systemd/system/${t}.timer" "/r/etc/systemd/system/${t}.timer"
      ln -sfn "/etc/systemd/system/${t}.timer" "/r/etc/systemd/system/timers.target.wants/${t}.timer"
    done
    apk add -q binutils zstd tar coreutils >/dev/null
    for deb in /pkg/*.deb; do
      d=$(mktemp -d); mkdir "$d/x"
      (cd "$d" && ar x "$deb" && tar -xf data.tar.zst -C "$d/x" --no-same-owner)
      # refuse hardlinks and any symlink that is absolute or resolves outside the package root
      [ -z "$(find "$d/x" -type f -links +1)" ] || { echo "hardlink in $deb" >&2; exit 1; }
      find "$d/x" -type l | while read -r l; do
        t=$(readlink "$l"); case "$t" in /*) echo "absolute symlink in $deb: $l" >&2; exit 1;; esac
        r=$(realpath -m "$(dirname "$l")/$t"); case "$r" in "$d/x"/*) ;; *) echo "escaping symlink in $deb: $l" >&2; exit 1;; esac
      done
      (cd "$d/x" && tar -cf - .) | tar -xf - -C /r --no-overwrite-dir --no-same-owner
      rm -rf "$d"
    done
    install -D -o 0 -g 0 -m 755 /overlay/usr/local/sbin/jarvis-wifi-power /r/usr/local/sbin/jarvis-wifi-power
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/system/jarvis-wifi-power.service \
      /r/etc/systemd/system/jarvis-wifi-power.service
    ln -sfn /etc/systemd/system/jarvis-wifi-power.service \
      /r/etc/systemd/system/multi-user.target.wants/jarvis-wifi-power.service
    install -D -o 0 -g 0 -m 755 /overlay/usr/local/sbin/jarvis-wifi-watchdog /r/usr/local/sbin/jarvis-wifi-watchdog
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/system/jarvis-wifi-watchdog.service \
      /r/etc/systemd/system/jarvis-wifi-watchdog.service
    install -D -o 0 -g 0 -m 755 /overlay/usr/local/sbin/jarvis-wifi-retry /r/usr/local/sbin/jarvis-wifi-retry
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/system/jarvis-wifi-retry.service \
      /r/etc/systemd/system/jarvis-wifi-retry.service
    ln -sfn /etc/systemd/system/jarvis-wifi-retry.service \
      /r/etc/systemd/system/multi-user.target.wants/jarvis-wifi-retry.service
    install -D -o 0 -g 0 -m 644 /overlay/etc/modprobe.d/jarvis-no-bluetooth.conf \
      /r/etc/modprobe.d/jarvis-no-bluetooth.conf
    install -D -o 0 -g 0 -m 644 /overlay/etc/modprobe.d/jarvis-mt76.conf /r/etc/modprobe.d/jarvis-mt76.conf
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/zram-generator.conf /r/etc/systemd/zram-generator.conf
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/network/05-eth0-off.network /r/etc/systemd/network/05-eth0-off.network
    install -D -o 0 -g 0 -m 755 /overlay/etc/nftables.conf /r/etc/nftables.conf
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/system/jarvis-claude-rc.service \
      /r/etc/systemd/system/jarvis-claude-rc.service
    install -d -o 0 -g 0 -m 700 /r/root/jarvis
    # dashboard files only; nodejs and avahi-daemon are apt-installed on the box (not in this image)
    install -D -o 0 -g 0 -m 644 /dashboard/server.mjs /r/opt/jarvis-dashboard/server.mjs
    install -D -o 0 -g 0 -m 644 /dashboard/index.html /r/opt/jarvis-dashboard/index.html
    install -D -o 0 -g 0 -m 644 /overlay/etc/systemd/system/jarvis-dashboard.service \
      /r/etc/systemd/system/jarvis-dashboard.service
    install -D -o 0 -g 0 -m 644 /overlay/etc/avahi/services/jarvis-dashboard.service \
      /r/etc/avahi/services/jarvis-dashboard.service
    # avahi itself is apt-installed on the box; if present, apply the IPv4-only / wlan0-only settings
    [ -f /r/etc/avahi/avahi-daemon.conf ] && sed -i -f /overlay/etc/avahi/avahi-daemon.conf.jarvis-sed /r/etc/avahi/avahi-daemon.conf

    install -m 600 /key.pub /r/root/.ssh/authorized_keys
    echo "${HOSTNAME_BOX}" > /r/etc/hostname

    apk add -q dtc >/dev/null
    DTB_DIR=$(ls -d /b/dtb-*)/amlogic
    cp "${DTB_DIR}/${BASE_DTB}" "${DTB_DIR}/${JAWS_DTB}"
    fdtput -t s "${DTB_DIR}/${JAWS_DTB}" /soc/usb@fe03a000 dr_mode host
    fdtput -t s "${DTB_DIR}/${JAWS_DTB}" /soc/usb@fe03a000/usb@fdd00000 status disabled
    # WiFi (MT7663U, internal USB) power is GPIOX_6 (offset 56). The generic DTB ties it to an SDIO
    # pwrseq on an empty SDIO slot, which drops the pin when the slot fails. Disable that path; the
    # pin is driven from userspace by jarvis-wifi-power (needs to power-cycle a hung chip).
    fdtput -t s "${DTB_DIR}/${JAWS_DTB}" /soc/mmc@fe088000 status disabled
    fdtput -t s "${DTB_DIR}/${JAWS_DTB}" /sdio-pwrseq status disabled
    sed "s#^dtb_img=.*#dtb_img=dtb-\${release}/amlogic/${JAWS_DTB}#" \
      /b/box-config/box-s905x4_generic.config > "/b/box-config/box-${BOX_CONFIG}.config"
    echo "bootargs5=usbcore.autosuspend=-1" >> "/b/box-config/box-${BOX_CONFIG}.config"

    sed -i "s/^box=/#box=/" /b/boot.config
    grep -q "^box=${BOX_CONFIG}\$" /b/boot.config || \
      sed -i "/^# Uncomment one of these box configs:/a box=${BOX_CONFIG}" /b/boot.config
    [ "$(grep -c "^box=" /b/boot.config)" = 1 ]
    echo "usb glue dr_mode: $(fdtget "${DTB_DIR}/${JAWS_DTB}" /soc/usb@fe03a000 dr_mode)"
    echo "dwc2 status: $(fdtget "${DTB_DIR}/${JAWS_DTB}" /soc/usb@fe03a000/usb@fdd00000 status)"
    echo "sdio mmc: $(fdtget "${DTB_DIR}/${JAWS_DTB}" /soc/mmc@fe088000 status), pwrseq: $(fdtget "${DTB_DIR}/${JAWS_DTB}" /sdio-pwrseq status)"
    echo "box bootargs: $(grep ^bootargs "/b/box-config/box-${BOX_CONFIG}.config")"
    echo "box config: $(grep ^dtb_img= /b/box-config/box-${BOX_CONFIG}.config)"

    echo "firmware:"; ls -l /r/lib/firmware/mediatek | grep 7663
    echo "wifi ssid: $(grep ssid= /r/root/wpa_supplicant.conf)"
    echo "wpa unit: $(readlink /r/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service)"
    echo "hostname: $(cat /r/etc/hostname)"
    echo "boot.config: $(grep ^box= /b/boot.config)"
  '

echo "Image ready: ${IMG}"
echo "SSH after boot: ssh -i ${SSH_KEY} root@<box-ip>"
