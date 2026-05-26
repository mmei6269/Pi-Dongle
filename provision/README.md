# Provision Bundle

This directory contains the Pi-side installer and runtime files for:

```text
USB audio host -> Pi Zero 2 W UAC2 gadget -> CamillaDSP -> PipeWire -> Bluetooth headphones
```

For the fresh-Pi walkthrough, use the top-level `README.md`. This file is the
short map for people changing the provision bundle.

## Main Commands

Install on the Pi:

```bash
sudo bash ./install.sh
```

Non-interactive install:

```bash
AIRPODS_MAC=AA:BB:CC:DD:EE:FF \
ENABLE_AIRPODS_PRO3_EQ=0 \
ENABLE_CROSSFEED=reference \
INSTALL_AAC_PLUGIN=0 \
sudo -E bash ./install.sh
```

Deploy from a laptop:

```bash
PI_HOST=<pi-user>@raspberrypi.local ./provision/deploy.sh
```

Verify a live dongle:

```bash
sudo /usr/local/bin/dongle-healthcheck.sh
PI_HOST=<pi-user>@raspberrypi.local ./provision/verify-live.sh
```

## Installer Options

- `AIRPODS_MAC`: headphone Bluetooth MAC address.
- `TARGET_USER`: user that owns the PipeWire session. Auto-detected from
  `sudo` on a normal install.
- `ENABLE_AIRPODS_PRO3_EQ=1`: install the AirPods Pro 3rd generation neutrality
  EQ preset.
- `ENABLE_CROSSFEED=reference`: install the researched FIR virtual-speaker
  crossfeed preset.
- `ENABLE_CROSSFEED=virtual`: install the simpler 4-filter virtual-speaker
  crossfeed preset.
- `ENABLE_CROSSFEED=monitor`: install the conservative monitor crossfeed preset.
- `ENABLE_CROSSFEED=classic` or `ENABLE_CROSSFEED=1`: install the low-latency
  crossfeed preset with direct-channel tilt plus main and early opposite-ear
  feeds.
- `ENABLE_CROSSFEED=0`: disable crossfeed. `none`, `off`, and `no` are accepted
  aliases.
- `INSTALL_AAC_PLUGIN=1`: build/install the optional PipeWire AAC Bluetooth
  codec plugin. This adds build dependencies and requires `libfdk-aac-dev`.
- `RESTART_GADGET_NOW=1`: attempt a guarded live USB cutover instead of waiting
  for reboot.
- `DISABLE_WIFI_AFTER_INSTALL=1`: turn Wi-Fi off after install. Leave unset on a
  fresh SSH install until USB management has been verified.
- `SKIP_APT=1`: skip apt work for an already-provisioned Pi.

## Crossfeed Options

Crossfeed is optional and separate from the AirPods Pro 3rd generation
neutrality EQ. The installer combines the selected EQ and crossfeed choices into
one installed CamillaDSP config at `/etc/camilladsp/airpods.yml`.

- `reference` is the most speaker-correct implementation. It uses FIR
  speaker-to-ear paths for +/-30-degree speakers, Brown/Duda-style head
  shadowing, Woodworth-style interaural timing, and phantom-center compensation
  to keep centered material tonally flat.
- `virtual` is the simpler virtual-speaker implementation. It uses a matrix with
  flat same-side paths and low-passed, delayed opposite-side paths for stronger
  speaker-like imaging without generic room coloration.
- `monitor` is subtler. It leaves direct left/right paths unshaped and adds only
  a low-passed, lightly delayed opposite-ear feed to soften hard pans.
- `classic` or `1` is the low-latency preset. It adds direct-channel tilt plus
  main and early opposite-ear feeds, making it more shaped than `monitor` and
  less speaker-matrix-like than `virtual`.
- `none` or `0` keeps clean passthrough unless the AirPods Pro 3rd generation
  neutrality EQ is enabled.

## Custom DSP Configs

The active runtime config is always `/etc/camilladsp/airpods.yml` on the Pi.
Edit that file and restart `camilladsp` to test a custom CamillaDSP config:

```bash
sudo cp /etc/camilladsp/airpods.yml /etc/camilladsp/airpods.yml.bak
sudo nano /etc/camilladsp/airpods.yml
sudo systemctl restart camilladsp
```

Keep capture set to `hw:UAC2Gadget,0` and playback set to `pipewire` unless you
are deliberately changing the dongle's audio path. For repo-managed presets,
start from one of the `airpods*.yml` files and install the finished config as
`/etc/camilladsp/airpods.yml`. Rerunning `install.sh` overwrites that runtime
file with the selected bundled preset.

## Files

- `install.sh`: installs dependencies, deploys runtime files, enables services,
  and prints pairing/validation next steps.
- `deploy.sh`: copies this bundle to a Pi over SSH and runs `install.sh`; falls
  back from `rsync` to `tar` when needed.
- `healthcheck.sh`: one-command runtime validation on the Pi.
- `verify-live.sh`: compares this repo's provisioned files against a live dongle
  over SSH.
- `usb-gadget-uac2-ecm.sh`: configfs UAC2 audio plus USB Ethernet gadget.
- `safe-usb-cutover.sh`: guarded live cutover helper with rollback timer.
- `usb-fallback-guard.sh`: restores `g_ether` if the composite gadget is
  unavailable.
- `run-camilladsp.sh`: waits for USB audio/PipeWire and runs CamillaDSP.
- `airpods-connect.sh`: reconnects the configured headphones and selects the
  PipeWire sink.
- `airpods*.yml`: CamillaDSP passthrough, EQ, crossfeed, and combined presets.
- `reference-speaker/*.txt`: FIR coefficients for the reference speaker
  crossfeed preset.
- `wireplumber/*.conf`: headless Bluetooth playback policy.
- `systemd/*.service`: runtime system units.
- `build-pipewire-aac-plugin.sh`: optional helper for images without the PipeWire
  AAC BlueZ codec plugin.

## Notes

- PipeWire/WirePlumber is the supported Bluetooth audio path.
- `bluealsa.service` is deprecated and kept only as a reference; the installer
  removes/disables BlueALSA runtime ownership.
- `safe-usb-cutover.sh` schedules automatic `g_ether` fallback after `180s`
  unless composite USB validation passes.
