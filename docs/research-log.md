# Research log

Each entry: date, what was tested or read, source, result. Keep **verified** separate from **unverified**.

## 2026-11-01

- Repo created. Phase 0 pending: identify the exact model of the box.

## 2026-11-01 (2)

- Decision: full Ubuntu, accepting the loss of Android TV.
- Model: MDZ-28-AA = TV Box S 2nd Gen (`jaws`), S905X4 according to external sources. **Unverified on the box.**
- ophub does not support S905X4 (I verified it: 0 entries in `model_database.conf`).
- Candidate: devmfc/debian-on-amlogic, Ubuntu 26.10 with DTB `s905x4_generic`. Its README says S905X4 has no sound.
- Details in 01-hardware-and-boot-paths.md (doc removed; superseded by the README).

## 2026-11-01 (3)

- Decision: voice goes through the phone app (microphone and speaker). The box does not need audio, so the S905X4 "No sound" is no longer a blocker.

## 2026-11-01 (4)

- Attack plan in 4 risk levels: 02-plan-de-ataque.md (doc removed; superseded by the README). No UART documentation was found for jaws.

## 2026-11-01 (5)

- Box data read over ADB (`docs/device-info/`): sc2/S905X4, 2 GB of RAM, MT7663 USB WiFi, no Ethernet, Android 11 build 683, AVB locked.
- The devmfc kernel includes `mt7663u.ko`. Whether it ships the firmware is not verified.

## 2026-11-01 (6)

- **Verified:** the devmfc Ubuntu image **does not ship** MT7663 firmware (`/lib/firmware/mediatek` only has `mt7668pr2h.bin`). Networking uses systemd-networkd + wpa_supplicant; `wpa_supplicant@wlan0` is not enabled out of the box.
- Default login: root / tvbox (according to the devmfc README). sshd has `PermitRootLogin yes`.
- `scripts/prepare-image.sh`: adds the firmware from linux-firmware, the WiFi from .env (PSK stored as a hash) and an SSH key. Tested on a copy of the image, rc=0.

## 2026-11-01 (7) — first Linux boot

- **Verified:** `adb reboot update` (no root, with a locked bootloader) boots the devmfc 6.18.59 kernel from the USB drive. The Xiaomi u-boot accepts the unsigned kernel.
- **Verified:** HDMI works (240x67 console) and the eMMC is 8 GB (`mmc1: 8GTF4R 7.28 GiB`).
- **Failure:** `dwc3-meson-g12a fe03a000.usb: switching to Device Mode` and then `Waiting for root device /dev/sda2...`. The only USB port is OTG, and with `dr_mode="otg"` it goes into device mode, so it never sees the USB drive. Photo: `device-info/boot1-usb-device-mode.jpg`.
- **Fix (untested):** DTB `meson-sc2-xiaomi-jaws.dtb` = the generic one with `/soc/usb@fe03a000 dr_mode=host` and dwc2 disabled. Selected with `box=xiaomi_jaws`.

## 2026-11-02 (8)

- **Verified:** with `box=xiaomi_jaws` (USB in host mode) Ubuntu boots fully to `jarvis login:`. The DTB fix works.
- **Failure:** the box does not show up on the network (0 hosts with SSH on 10.128.196.0/24 after boot). Cause unknown.
- Added `overlay/` with `jarvis-diag.service`: 90 s after boot it writes the WiFi/USB logs to `/boot/diag/`, which can be read from the Mac.

## 2026-11-02 (9) — WiFi powered off

- **Verified** (`device-info/diag-boot3.txt`): only the storage drive appears on the Linux USB bus (`1-2 0718:7722`). The MT7663 does not enumerate, so there is no `wlan0` and `wpa_supplicant@wlan0` fails on a dependency. The firmware is installed.
- Android exposes the DT nodes `aml_wifi` (`power_on-gpios`, `interrupt-gpios`) and `wlpm_dev` (`gpio_reset`, `vcc`), but reading their values gives Permission denied without root. There is an exported GPIO 474 on `pinctrl@4000` (base 425, offset 49 = GPIOH_8 according to [meson-sc2-gpio.h](https://nest-open-source.googlesource.com/manifest_repos/amlogic-driver/+/refs/heads/main/include/dt-bindings/gpio/meson-sc2-gpio.h)).
- Hypothesis (unverified): the generic DTB ties GPIOX_6 (offset 56) to an sdio-pwrseq of an empty SDIO slot (`mmc2: Failed to initialize a non-removable card`), and that leaves the WiFi powered off.
- Attempt 1: SDIO `mmc@fe088000` and `sdio-pwrseq` disabled, and a `gpio-hog` driving GPIOX_6 high. If it does not work, the next candidate is GPIOH_8.

## 2026-11-02 (10) — the WiFi chip powers on

- **Verified** (`device-info/diag-boot4.txt`): with the GPIOX_6 hog driven high, the MT7663 enumerates (`1-1 0e8d:7663`) and `wlan0` appears (MAC 4c:31:2d:…). **GPIOX_6 is the WiFi power pin.**
- **Failure:** `mt7663u: Failed to get patch semaphore` and then `wlan0: Input/output error`. `btusb` probes the same combo chip at the same time (12.139 s and 12.144 s) and holds the patch semaphore.
- Fix (untested): blacklist `btusb`/`btmtk` (`CONFIG_BT_HCIBTUSB=m`), plus `jarvis-wifi-retry.service`, which reloads `mt7663u` up to 5 times if `wlan0` does not come up.

## 2026-11-02 (11) — WiFi connects on Ubuntu

- **Verified** (`device-info/diag-boot5.txt`, uptime 2 min): `wlan0` with 10.128.196.91/24, default route via 10.128.196.1 and `WPA: Key negotiation completed` with <home-ssid> at 5500 MHz. The btusb blacklist solved the semaphore: `jarvis-wifi-retry` says `wlan0 up (try 1)`.
- From the Mac, 20 s after boot, port 22 answered on .91 (MAC 4c:31:2d:xx:xx:xx = wlan0). Then the SSH banner timed out and pings gave 0/20. **The drop is not diagnosed**: it happened after the only snapshot.
- The router went from 5540 MHz (seen on Android) to 5500 MHz (seen on Linux). These are DFS channels; the cause is still unverified.
- Changes: `power_save off`; `jarvis-wifi-watchdog.timer` every 60 s (ping the gateway, then restart wpa and reload mt7663u); `jarvis-diag.timer` every 3 min, keeps the last 30 snapshots.

## 2026-11-02 (12) — MT7663 firmware hang

- **Verified** (photo `device-info/boot6-mt7663-mcu-timeout.jpg`): at 566 s `mt7663u 1-1:1.2: Message 000000ef (seq 1) timeout` appears. The chip's MCU stops responding; the watchdog reloaded the driver and `wlan0` was left without an IP. Before that the box had IP .92 and answered ARP (MAC 4c:31:2d:xx:xx:xx) but not ICMP.
- Hypothesis (unverified): the chip is never powered off between Android and Linux (`reboot update` is a warm boot and the hog kept GPIOX_6 high at all times), so reloading the module does not reset it.
- Changes: the hog is removed. `jarvis-wifi-power.service` (libgpiod 2.2.5 from ports.ubuntu.com) drives GPIOX_6 low for 2 s, drives it high, waits for 0e8d:7663 to enumerate and loads mt7663u; mt7663u is blacklisted so it does not load on its own earlier. retry and watchdog now do a power cycle instead of reloading the module. `usbcore.autosuspend=-1` is added.
- Tested in chroot: `gpioset (libgpiod) v2.2.5` runs inside the rootfs.

## 2026-11-02 (13) — SSH to Ubuntu working

- **Verified:** first SSH to the box (`root@10.128.196.93`, key `~/.ssh/xiaomibox_ed25519`). Ubuntu 26.10, kernel 6.18.59, wlan0 with 10.128.196.93/24, power save off, 1.6 GiB free of 1.9 GiB, NTP synchronized (the date went from Oct 26 to Nov 02), `ping 1.1.1.1` rtt 2.7 ms.
- **Verified:** `jarvis-wifi-power` does the power cycle with `gpiochip0 line 56` and the chip enumerates again in ~1 s.
- **Verified:** the link dropped at ~2.5 min (gateway not answering, although still associated to AP-A at 5500 MHz) with `mt7663u: timed out waiting for pending tx`. The watchdog restarted wpa (no effect), did a power-cycle and logged "recovered after power cycle" 58 s later. It re-associated with another AP (AP-B, 5600 MHz).
- Pending: measure stability over a longer period, and the root cause of the TX hangs (DFS channels, the 20200604 firmware or the driver).

## 2026-11-02 (14) — eMMC backup and stability

- **Verified:** read-only backup of the original eMMC on the USB drive, `/root/emmc-backup/` (by the user's decision it stays only on the USB drive, not on the Mac). `mmcblk1` 7,818,182,656 bytes → `mmcblk1.img.zst` 5.79 GB. Also `mmcblk1boot0/1.img` (4 MiB each, identical), `uboot-env.txt` (`fw_printenv` reads the environment: 10,939 bytes) and the partition table. `verify.sh`: device sha256 = decompressed image sha256 for all 3 → **VERIFIED**.
- Stability: monitor from the Mac with a ping every 10 s, 15 min → 90/90 OK. Over 32 min of uptime, only 1 drop (at ~2.5 min, AP-A at 5500 MHz) and 1 `timed out waiting for pending tx` in dmesg. Since it moved to AP-B (5600 MHz), 0 drops in ~30 min. The sample is too small to say it is solved; in the previous session the drop came at ~9 min.

## 2026-11-02 (15) — the failure is in TX, not in SSH

- **Hypothesis disproven (corrected):** I thought it was the USB bus or a stuck disk, and later ssh socket activation. Both were false. `diag-boot7-up2724s.txt` was written at 45 min (the disk and the system were fine, load 0.00), and `journalctl -u ssh` shows that sshd did receive every attempt (`Connection closed by 10.128.196.72 … [preauth]`, 9 times between 23:48:38 and 23:51:03) while the client never received the banner.
- **Verified:** the failure mode is that the box stops delivering outgoing TCP data, while ping (even at 1400 bytes) and the TCP handshake still get through. The watchdog, which only pinged, was slow to detect it (this time ~3 min, until ping also failed).
- Changes applied **live** (without reflashing, so as not to erase `/root/emmc-backup`): the watchdog adds a real TCP test (`GET /cdn-cgi/trace` to 1.1.1.1:80 over `/dev/tcp`, the response must start with `HTTP/`); `options mt76_usb disable_usb_sg=1` (at runtime via /sys and in modprobe.d) and a power-cycle of the chip. Measurement start: 18:15 EST, SSH every 30 s for 30 min.

## 2026-11-02 (16) — Claude Code installed + multiboot written

- **Verified:** Claude Code 2.1.316 installed with the native installer (`/root/.local/bin/claude`, with a symlink in `/usr/local/bin`). Also curl, git and tmux. The install ran detached with `systemd-run` and the WiFi held up through the download.
- **Verified:** with HDMI hot-unplugged (18:34), `HDMI-A-1` goes to `disconnected` and SSH and WiFi keep working. A cold boot without HDMI is still to be verified.
- **Verified:** `aml-multiboot-setup.sh` was run (exit 0). Environment diff: only the variables `cmd_boot_*`, `boot_*_order` and `boot_emmc_parts` are added, and `bootcmd` changes from `run storeboot` to `run cmd_boot_get_order; for var in "${boot_order}"; do run cmd_boot_${var}; done; run cmd_boot_org`, with `cmd_boot_org=run storeboot` (Android remains as the fallback). Backups: `/root/uEnv.bak` and `/root/emmc-backup/uboot-env-{before,after}-multiboot.txt`, plus the environment inside the mmcblk1 image.
- Still to verify: that Xiaomi's 2023 u-boot (`01.01.230202`) honors `bootcmd` from the environment on a cold boot.

## 2026-11-02 (17) — boots Ubuntu on its own, without Android and without HDMI

- **Verified:** with the USB drive inserted and HDMI unplugged, power was cut at 18:44:08 EST and by 18:44:51 SSH was already open on .93 (43 s, no ADB at any point). On the box: `up 2 min`, `root=/dev/sda2`, `HDMI-A-1: disconnected`, jarvis-wifi-power and wpa active, claude 2.1.316. **Xiaomi's 2023 u-boot honors the multiboot `bootcmd`.** A cold boot without HDMI also works.
- **Verified:** SSH monitor every 30 s from 18:15 to 18:45 (with `disable_usb_sg=1`): 57 ok, 1 FAIL at 18:44:26, which was the power cut of the test. 0 WiFi failures in ~29 min, including the Claude Code install download. It is a short sample: a long (overnight) test is still needed.
- Pending: fallback to Android without the USB drive (not tested); zram; disable eth0 (there is no physical connector).

## 2026-11-02 (18) — drop with the watchdog green

- Drop at ~18:50 EST (boot4): from the Mac, ping answers and TCP connects, but the SSH banner does not arrive, same as before. Recovered by cutting power at ~19:02.
- **Hypothesis disproven (verified):** "the USB gets stuck". `/boot/diag` kept writing every 3 min during the drop (boot4-up00492s 00:52, 00679s 00:55, 00875s 00:59 in box time), with load 0.03.
- **Verified:** during the drop the box was still `Connected to AP-A`, 400 Mbit/s tx/rx, and the watchdog (ping to the gateway + HTTP GET to 1.1.1.1, both with TOS 0) **logged no failures** after its 00:47 recovery. In other words: the box's TOS 0 traffic worked and SSH to the Mac did not.
- New hypothesis (unverified): a single WMM queue of the MT7663 hangs. SSH sets DSCP and goes out through a different queue than ping and the probe (BE). The watchdog now pings the gateway with TOS 0x00/0x20/0x80/0xc0 (BE/BK/VI/VO) and logs `failed_ac=[...]`. The next drop confirms or disproves this.
- zram: the kernel does not have zstd (`zram_generator: algorithm "zstd" not recognised`) and uses lzo-rle. The config was corrected to lzo-rle. eth0 stays down with `05-eth0-off.network` (verified: `eth0 DOWN`).

## 2026-11-02 (19) — cause found: the VO (voice) queue hangs

- **Verified:** watchdog at 01:06:59 (box time): `link check failed (failed_ac=[VO ] tcp_ok=yes)`. Only the voice WMM queue was failing; BE/BK/VI and the TCP probe were OK. Recovered with a power-cycle (~40 s). Before that there was another event at 01:03:40 that also recovered on its own.
- The version is OpenSSH_10.5p1. I believe its default IPQoS sends interactive traffic to VO; **I did not verify that against the OpenSSH documentation**. What is verified is that the SSH failure coincides with the VO hang.
- Fix (downgrade only): nftables `inet jarvis_qos`, which sets DSCP cs0 on everything leaving through wlan0 except ICMP (so the watchdog can keep testing each queue). Rules scoped with `meta nfproto ipv4/ipv6`. Verified with counters: ipv4 packets 4, ipv6 0. `nftables.service` enabled.
- Claude Code Remote Control is set up as a service (`jarvis-claude-rc.service`, tmux `claude-rc`, in `/root/jarvis`). It needs the user to confirm the trust prompt once.

## 2026-11-02 (20) — dashboard + jarvis.local

- **Verified:** `avahi-daemon` 0.8 and `nodejs` 24.19.0 installed via apt on the box. From the Mac, `http://jarvis.local:8080/` → 200 and `http://10.128.196.93:8080/` → 200. mDNS does work on <home-ssid> (`dscacheutil` resolves jarvis.local).
- Dashboard `dashboard/server.mjs` (only Node built-in modules, read-only, GET only; POST → 405), `jarvis-dashboard` service with DynamicUser + systemd-journal + ProtectSystem=strict/ProtectHome. It shows: uptime/load, WiFi (SSID, BSSID, MHz, dBm, TX), RAM/zram/disk/temperature, service status and watchdog events from the current boot.
- **Measured** (direct read, `dd iflag=direct`, 256 MiB): eMMC `mmcblk1` 176 MB/s, USB `sda` 32 MB/s. eMMC write was not measured (it would mean writing over Android). According to the other session, the USB drive writes at ~6 MB/s.
- No authentication: anyone on the network can see the status (there are no actions). The root password is still `tvbox`; disabling SSH password login is pending.

## 2026-11-02 (21) — watchdog ignores VO hangs; dashboard on :80

- **Verified:** the VO hangs repeat every few minutes (01:19:26 and 01:21:43, on two different APs). With the previous watchdog there were **9 power-cycles** in that boot, each one ~1 min without network (one cut off an scp). Since nftables already moves all non-ICMP traffic off VO, the watchdog now only logs failures that are VO-only (`vo hang (ignored, traffic steered to BE)`) and acts if BE/BK/VI or the TCP probe fails. The logic was tested with 5 simulated combinations.
- Dashboard: the Host header must be a name/IP of the box (anti DNS rebinding). Verified: `Host: evil.example.com` → 421, jarvis.local → 200. Moved to **:80** (`AmbientCapabilities=CAP_NET_BIND_SERVICE` with DynamicUser). `http://jarvis.local` → 200.

## 2026-11-02 (22) — jarvis.local stopped resolving (avahi renamed itself)

- **Verified:** avahi at 01:22:16: `Host name conflict, retrying with jarvis-2` during a WiFi power-cycle, and it ended up as `Host name is jarvis-2.local`. From the Mac, jarvis.local gave `Unknown host`.
- Fix: avahi with `use-ipv6=no`, `allow-interfaces=wlan0` (original saved in /root/avahi-daemon.conf.orig); the watchdog queries the name over D-Bus (`GetHostNameFqdn`) every minute and restarts avahi if it is not `jarvis.local`. Verified: `jarvis-2.local` → restart → `jarvis.local`, and the Mac gets HTTP 200 again.
- **Verified:** the IPv6 ULA `fdxx:xxxx:xxxx:xxxx:5f02:b6c0:ed64:94a2` is the same in diag-boot5 (when the IPv4 was .91) and now (.93). systemd-networkd's `Token=prefixstable` keeps it stable across reboots and IPv4 changes, as long as the router advertises the same prefix. It can serve as a fixed address for IPv6 clients (the TV is not verified).
