# Tutorial: Ubuntu home server on a Xiaomi TV Box S (2nd Gen)

This guide goes from a stock Xiaomi box to an always-on Ubuntu server you can reach at `http://jarvis.local`, with Claude Code installed. Every step lists the commands and what you should see. If something goes wrong, check [Troubleshooting](#troubleshooting).

**Time:** about 1–2 hours. **Difficulty:** comfortable with a terminal.

> ⚠️ **Read before starting**
> - Everything on the USB stick gets erased.
> - Android on the box is left untouched until step 6. Step 6 changes the bootloader *environment* (not the bootloader itself) and could make the box unbootable. Do the backup in step 5 first.
> - Only tested on **MDZ-28-AA** (`jaws`, Amlogic S905X4). Other models need a different device tree.

---

## 0. What you need

| Item | Notes |
|---|---|
| Xiaomi TV Box S 2nd Gen, **MDZ-28-AA** | The model number is on the label under the box |
| USB stick, 8 GB or more | Gets erased. A faster stick or a USB SSD makes the system much snappier |
| A Mac or Linux computer | With [Docker](https://www.docker.com/) (to edit the image's Linux filesystem) and `adb` |
| The box and computer on the same WiFi | WPA2-PSK network. 5 GHz works |
| A TV or monitor (HDMI) | Only for the first boots, to watch what happens |

Install `adb`:

```sh
brew install --cask android-platform-tools   # macOS
sudo apt install adb                          # Debian/Ubuntu
```

Get the repo:

```sh
git clone https://github.com/jhonnrodr/xiaomibox-ubuntu.git
cd xiaomibox-ubuntu
```

---

## 1. Prepare the box (still on Android)

1. On the box: **Settings → System → About**, then click **Android TV OS build** 7 times. This unlocks Developer options.
2. **Settings → System → Developer options**: turn on **USB debugging** and **Network debugging** (the name varies by firmware).
3. **Settings → Network & Internet → your WiFi**: write down the box's **IP address**.

Check the connection and confirm it's the right hardware. This is read-only; nothing on the box changes:

```sh
./scripts/collect-device-info.sh <box-ip>
```

A prompt appears on the TV: choose **Always allow from this computer**. In the saved file under `docs/device-info/`, you should see:

```
ro.product.device=jaws
ro.board.platform=sc2
```

> **macOS: `failed to connect … No route to host`?** macOS privacy settings can block the `adb` binary from your local network. Run the relay in another terminal and connect through it:
> ```sh
> python3 -I scripts/adb-bridge.py <box-ip>    # leave it running
> adb connect 127.0.0.1:15555
> ```
> Then use `adb -s 127.0.0.1:15555 …` wherever this guide says `adb`.

---

## 2. Build the image (on your computer)

1. **Download the base image** from [devmfc/debian-on-amlogic releases](https://github.com/devmfc/debian-on-amlogic/releases): the file named `Devmfc_Ubuntu-Stonking_<kernel>-meson64_Minimal-<date>.img.xz`. This project was built with kernel `6.18.59`.

   ```sh
   mkdir -p images && cd images
   # download the .img.xz here, then:
   xz -dk Devmfc_Ubuntu-Stonking_*.img.xz
   cd ..
   ```

2. **Add your WiFi credentials:**

   ```sh
   cp .env.example .env
   # edit .env and fill in:
   #   WIFI_SSID="YourNetwork"
   #   WIFI_PSK="your-password"
   ```

   `.env` is git-ignored. The password goes into the image as a WPA hash, not as plaintext.

3. **Customize the image** (Docker must be running):

   ```sh
   ./scripts/prepare-image.sh images/Devmfc_Ubuntu-Stonking_*.img
   ```

   The script downloads the WiFi firmware and the `libgpiod` tools and checks their hashes. It creates an SSH key at `~/.ssh/xiaomibox_ed25519` and modifies the image. It should end with:

   ```
   usb glue dr_mode: host
   sdio mmc: disabled, pwrseq: disabled
   box config: dtb_img=dtb-${release}/amlogic/meson-sc2-xiaomi-jaws.dtb
   wifi ssid:  ssid="YourNetwork"
   hostname: jarvis
   boot.config: box=xiaomi_jaws
   Image ready: …
   ```

---

## 3. Flash the USB stick

**Find the stick.** Getting this wrong erases the wrong disk.

macOS:

```sh
diskutil list external physical       # find your stick, e.g. /dev/disk4
diskutil unmountDisk /dev/diskN
sudo dd if=images/Devmfc_Ubuntu-Stonking_*.img of=/dev/rdiskN bs=4m status=progress && sync
```

Linux:

```sh
lsblk -o NAME,SIZE,MODEL,TRAN          # find your stick, e.g. /dev/sdb (TRAN = usb)
sudo dd if=images/Devmfc_Ubuntu-Stonking_*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

When it finishes you should see about `1058013184 bytes transferred`. The stick then has two partitions: `BOOT` (FAT, ~256 MB) and a Linux partition.

> Tip: on macOS, use `rdiskN` (raw device), which is much faster than `diskN`. If you're scripting it, check the exact byte size with `diskutil info diskN` before `dd`.

---

## 4. First boot into Ubuntu

1. Plug the stick into the box's USB port, with the box on and Android running.
2. From your computer:

   ```sh
   adb connect <box-ip>:5555
   adb reboot update
   ```

   `reboot update` makes the stock bootloader run the `aml_autoscript` on the stick. No unlock or root is needed.
3. Watch the TV. You should see Linux boot text, then a **DEVMFC TV-Box** banner and `jarvis login:`. The banner shows the IP address once WiFi connects (it can take ~30 s).
4. Log in from your computer:

   ```sh
   ssh -i ~/.ssh/xiaomibox_ed25519 root@<ip-from-the-banner>
   ```

   The IP usually differs from Android's. If the banner says `127.0.0.1`, WiFi didn't come up; see [Troubleshooting](#troubleshooting).

Quick check on the box:

```sh
hostname                     # jarvis
ip -4 -br addr show wlan0    # your IP
systemctl is-active jarvis-wifi-power wpa_supplicant@wlan0
```

---

## 5. Back up the box's internal memory (eMMC)

Do this **before** step 6. It reads the whole eMMC (Android plus the bootloader environment) into a compressed file on the USB stick and changes nothing on the eMMC.

```sh
mkdir -p /root/emmc-backup && cd /root/emmc-backup
fw_printenv > uboot-env.txt
dd if=/dev/mmcblk1boot0 of=mmcblk1boot0.img bs=1M
dd if=/dev/mmcblk1boot1 of=mmcblk1boot1.img bs=1M
dd if=/dev/mmcblk1 bs=4M | zstd -3 -T0 -o mmcblk1.img.zst      # ~10 min, ~6 GB
```

**Verify that it restores to exactly the same bytes** (the two hashes must match):

```sh
sha256sum < /dev/mmcblk1
zstd -dc mmcblk1.img.zst | sha256sum
```

> ⚠️ This backup lives on the USB stick. **If you re-flash the stick with `dd`, the backup is gone.** Copy it somewhere else first if you plan to re-flash. After this point, make changes live over SSH instead of rebuilding the image.

---

## 6. Boot Ubuntu automatically on power-on

Right now every reboot goes back to Android. devmfc's multiboot script sets the bootloader to try **SD → USB → eMMC → original Android**:

```sh
cd /root
./aml-multiboot-setup.sh        # answer y; it saves the old environment to /root/uEnv.bak
fw_printenv bootcmd             # should now start with: run cmd_boot_get_order; …
fw_printenv cmd_boot_org        # should be: run storeboot   (the Android fallback)
```

**Test it:** unplug the box's power, wait 5 s, plug it back in. Leave the USB stick in; HDMI can be unplugged. Within about 45 s, SSH should work again, and Android never shows up. Without the stick, the box should fall back to Android. That fallback wasn't exercised while building this project.

---

## 7. Server extras

All of this runs **on the box** over SSH.

**Packages** (the USB stick is slow, so this takes a few minutes):

```sh
apt-get update
apt-get install -y curl git tmux nodejs avahi-daemon nftables systemd-zram-generator
```

**WiFi fix.** All traffic goes through the normal queue. `/etc/nftables.conf` is already in the image:

```sh
systemctl enable --now nftables
nft list ruleset | grep dscp     # two rules: ip / ip6 dscp set cs0
```

If that prints nothing, the package replaced the file. Copy `overlay/etc/nftables.conf` from the repo to `/etc/nftables.conf` and run `systemctl restart nftables`.

**`jarvis.local` name** (avahi on IPv4 and WiFi only, which avoids a self-renaming bug):

```sh
sed -i 's/^use-ipv6=yes$/use-ipv6=no/; s/^#allow-interfaces=.*/allow-interfaces=wlan0/' /etc/avahi/avahi-daemon.conf
systemctl restart avahi-daemon
```

**Compressed swap** (`/etc/systemd/zram-generator.conf` is in the image):

```sh
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0
swapon --show                    # /dev/zram0 ~960M
```

**Status dashboard:**

```sh
systemctl enable --now jarvis-dashboard
```

Open **http://jarvis.local** on any device on your network.

**Secure SSH** (strongly recommended: the image's default root password is public):

```sh
passwd                                                        # set a new root password
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/10-keys-only.conf
systemctl reload ssh
```

Check it took effect: `sshd -T | grep -i passwordauthentication` should print `no`. If it says `yes`, the main `/etc/ssh/sshd_config` sets it earlier or doesn't include `sshd_config.d`; set it there instead. (This step wasn't run on the reference box while writing this guide.)

Keep your current SSH session open and test a **new** login with your key before closing it.

---

## 8. Claude Code

```sh
curl -fsSL https://claude.ai/install.sh | bash
ln -sfn "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude
claude --version
claude                           # first run: sign in with the link it prints
```

**Remote Control on boot** (drive the box's Claude from claude.ai or the Claude app):

```sh
mkdir -p /root/jarvis
systemctl enable --now jarvis-claude-rc
tmux attach -t claude-rc         # answer the "Trust /root/jarvis?" prompt with y
```

Detach with **Ctrl+b**, then **d**. The session keeps running. `claude -p "…"` runs one prompt and exits, which is the building block for scripts and APIs.

---

## 9. Check that everything is healthy

```sh
systemctl is-active jarvis-wifi-power jarvis-wifi-watchdog.timer nftables avahi-daemon jarvis-dashboard ssh
journalctl -b -u jarvis-wifi-watchdog | grep -E "failed|recovered|vo hang"
ls /boot/diag/                   # a snapshot every 3 minutes
```

Or just open **http://jarvis.local**. The "WiFi watchdog" card shows real failures (the ones that restarted WiFi) separately from harmless VO-queue hangs.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| TV stops at `Waiting for root device /dev/sda2…` | USB port in device mode (`switching to Device Mode`) | The image must use `box=xiaomi_jaws` (custom DTB). Re-run `prepare-image.sh` |
| Banner says `127.0.0.1`, no `wlan0` | WiFi chip powered off | `systemctl status jarvis-wifi-power`; it should log `USB 0e8d:7663 enumerated` |
| `mt7663u: Failed to get patch semaphore` | Bluetooth driver racing the WiFi driver | `/etc/modprobe.d/jarvis-no-bluetooth.conf` must blacklist `btusb` |
| Ping works but SSH says `banner exchange` timeout | Chip hung its voice (VO) queue | `systemctl enable --now nftables` (step 7); the watchdog handles the rest |
| `jarvis.local` stops resolving | avahi renamed itself to `jarvis-2.local` | Step 7 avahi settings; the watchdog also reclaims the name each minute |
| `adb: No route to host` on macOS | macOS Local Network privacy blocks `adb` | `scripts/adb-bridge.py` (step 1) |
| Power-on boots Android | Multiboot not set, or stick not detected | Redo step 6; use `adb reboot update` meanwhile |
| Need logs but there's no network | — | Power off, put the stick in your computer: `BOOT/diag/*.txt` is readable FAT |

The full story behind each fix, with the log lines, is in [`research-log.md`](research-log.md).

## Undo

- **Back to Android:** remove the USB stick and power-cycle (the multiboot fallback; not exercised during this project).
- **Restore the bootloader environment:** `fw_setenv bootcmd "run storeboot"` (from Ubuntu), or restore from `/root/uEnv.bak`.
- **Restore the whole eMMC** (last resort, overwrites everything on it): `zstd -dc /root/emmc-backup/mmcblk1.img.zst | dd of=/dev/mmcblk1 bs=4M conv=fsync`
