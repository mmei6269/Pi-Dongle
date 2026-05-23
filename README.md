# Pi Zero 2 W USB Audio to Bluetooth Headphones Dongle

Turn a clean Raspberry Pi Zero 2 W into a USB audio device that plays to
Bluetooth headphones:

```text
phone / tablet / computer
  -> USB audio into the Pi Zero 2 W
  -> CamillaDSP
  -> PipeWire + WirePlumber
  -> Bluetooth A2DP headphones
```

The default DSP preset is clean passthrough. During install you can optionally
enable AirPods Pro 3rd generation neutrality EQ, a crossfeed preset, or both.
If you want crossfeed, the virtual-speaker preset is the recommended
implementation for most listeners.

## Motivation

iOS does not provide a true system-wide audiophile DSP chain. This project is a
portable workaround: plug the Pi into an iPhone, iPad, computer, or other USB
audio host, let CamillaDSP apply EQ and crossfeed, then keep the convenience of
wireless AirPods playback.

The goal is the comfort and utility of AirPods with a more audiophile-friendly
signal path: corrected tonality, virtual-speaker crossfeed, no wired IEM cable,
and continued access to AirPods features such as noise cancellation and
transparency mode. For people already willing to carry a USB DAC and wired IEMs,
this is an alternate portable stack that keeps the listening experience wireless.

The AirPods Pro 3rd generation neutrality EQ preset is a personal neutrality
tuning derived from the Hangout Audio measurement database, with the treble
adjusted by ear. Treat it as a starting point, not a reviewed reference target.

## Audio Caveats

- This is not a lossless wireless chain. The Pi receives USB audio, processes it
  locally, then transmits Bluetooth A2DP audio to the headphones.
- The USB gadget is configured for 48 kHz, 16-bit, stereo audio. Source devices
  may resample before sending audio to the dongle.
- Bluetooth playback uses AAC only when the PipeWire BlueZ AAC codec plugin is
  available. On images without that plugin, the installer falls back to SBC for
  stability.
- Expect added latency from USB buffering, CamillaDSP processing, PipeWire, and
  Bluetooth. This is intended for music listening, not live monitoring, gaming,
  or video work where tight sync is critical.
- The runtime path is playback-only A2DP. It does not provide headset
  microphone input, call audio, or bidirectional hands-free behavior.
- AirPods noise cancellation and transparency mode remain handled by the
  AirPods themselves, but Apple-specific host integrations such as Spatial Audio
  head tracking, battery widgets, and automatic device switching should not be
  assumed to work through this bridge.

## Hardware

- Raspberry Pi Zero 2 W.
- MicroSD card with Raspberry Pi OS Lite 64-bit.
- USB data cable connected to the Pi Zero `USB` port, not the power-only port.
- Bluetooth headphones.
- Temporary internet access for the first install.

## Fresh Pi Install

1. Flash Raspberry Pi OS Lite 64-bit, create any username, enable SSH, and boot
   the Pi.
2. Find the Bluetooth MAC address for your headphones. It looks like
   `AA:BB:CC:DD:EE:FF` and is usually shown in your phone/computer Bluetooth
   details. If you need to scan from the Pi, run `bluetoothctl scan on` while the
   headphones are in pairing mode.
3. SSH into the Pi and run the installer:

```bash
ssh <pi-user>@raspberrypi.local
sudo apt-get update
sudo apt-get install -y --no-install-recommends git
git clone https://github.com/mmei6269/Pi-Dongle.git
cd Pi-Dongle/provision
sudo bash ./install.sh
```

The installer asks for the headphone Bluetooth MAC address and the optional DSP
choices. It leaves Wi-Fi enabled so a fresh SSH install does not strand you
before USB management is verified.

After install, pair the headphones once:

```bash
bluetoothctl
power on
agent on
default-agent
scan on
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
connect AA:BB:CC:DD:EE:FF
quit
```

Reboot to load the Pi USB device overlay:

```bash
sudo reboot
```

After reconnecting, run:

```bash
sudo /usr/local/bin/dongle-healthcheck.sh
```

Healthy state:

- `bluetooth`, `camilladsp`, `airpods-connect`, and `usb-gadget` are active.
- `arecord -l` shows `UAC2Gadget`.
- `aplay -L` shows `pipewire`.
- `wpctl status` shows the CamillaDSP stream routed to the headphones.
- USB Ethernet management is available on `192.168.7.2/24` and
  `169.254.64.64/16`.

## Non-Interactive Install

```bash
AIRPODS_MAC=AA:BB:CC:DD:EE:FF \
ENABLE_AIRPODS_PRO3_EQ=0 \
ENABLE_CROSSFEED=virtual \
sudo -E bash ./install.sh
```

`ENABLE_CROSSFEED` accepts either an on/off value or a named preset:

- `0`, `none`, `off`, `no`, or an empty value disables crossfeed.
- `virtual` selects the recommended virtual-speaker implementation. It uses a
  4-filter speaker-to-ear matrix: flat ipsilateral paths plus low-passed,
  delayed contralateral paths for a more speaker-like presentation without
  generic room or pinna coloration.
- `monitor` selects the conservative monitor crossfeed preset: flat direct
  left/right paths plus a low-passed, lightly delayed opposite-ear feed for
  softer hard pans with minimal tonal change.
- `classic`, `1`, `on`, `yes`, or `low-latency` selects the low-latency
  crossfeed preset: direct-channel tilt plus main and early opposite-ear feeds.
  It is more shaped than `monitor` and less speaker-matrix-like than `virtual`.

`ENABLE_AIRPODS_PRO3_EQ=1` is independent from crossfeed. When both are enabled,
the installer chooses the matching combined EQ plus crossfeed CamillaDSP preset.

Set `DISABLE_WIFI_AFTER_INSTALL=1` only after you have confirmed USB Ethernet
management works. Set `RESTART_GADGET_NOW=1` only on an already-running Pi where
you want to attempt a guarded live USB cutover instead of rebooting.

## Deploy From Another Machine

From this repo on your laptop:

```bash
PI_HOST=<pi-user>@raspberrypi.local ./provision/deploy.sh
```

This copies only the provision bundle to the Pi, so the Pi does not need Git. If
`rsync` is missing locally or remotely, the deploy script falls back to
`tar` over SSH.

For an already-provisioned dongle with no internet:

```bash
PI_HOST=<pi-user>@raspberrypi.local SKIP_APT=1 ./provision/deploy.sh
```

## DSP Presets

- `provision/airpods.yml`: clean passthrough.
- `provision/airpods-pro-3-neutral.yml`: AirPods Pro 3rd generation neutrality
  EQ.
- `provision/airpods-crossfeed.yml`: neutral crossfeed without headphone EQ.
- `provision/airpods-monitor-crossfeed.yml`: conservative monitor crossfeed
  without headphone EQ.
- `provision/airpods-virtual-speaker-crossfeed.yml`: recommended 4-filter
  virtual-speaker crossfeed without headphone EQ.
- `provision/airpods-pro-3-neutral-crossfeed.yml`: AirPods Pro 3rd generation
  neutrality EQ plus classic low-latency crossfeed.
- `provision/airpods-pro-3-neutral-monitor-crossfeed.yml`: AirPods Pro 3rd
  generation neutrality EQ plus conservative monitor crossfeed.
- `provision/airpods-pro-3-neutral-virtual-speaker-crossfeed.yml`: AirPods Pro
  3rd generation neutrality EQ plus recommended 4-filter virtual-speaker
  crossfeed.

The installed runtime config is `/etc/camilladsp/airpods.yml`. Change bundled
DSP choices by rerunning `install.sh`.

## Custom DSP Configs

Users who want their own EQ, crossfeed, loudness, or other CamillaDSP processing
can edit the installed config directly on the Pi:

```bash
sudo cp /etc/camilladsp/airpods.yml /etc/camilladsp/airpods.yml.bak
sudo nano /etc/camilladsp/airpods.yml
sudo systemctl restart camilladsp
```

Keep the existing `devices` section unless you intentionally change the runtime
audio path. The capture device should stay `hw:UAC2Gadget,0`, and playback
should stay `pipewire` for the USB-to-Bluetooth pipeline.

For repo-managed changes, copy the closest preset in `provision/airpods*.yml`,
edit the filters, mixers, or pipeline, then install that file as
`/etc/camilladsp/airpods.yml` and restart `camilladsp`. Rerunning `install.sh`
will replace `/etc/camilladsp/airpods.yml` with one of the bundled presets, so
save custom configs under a separate filename if you want to keep them.

## Public Use Notes

- The installer is intended for a fresh Raspberry Pi OS Lite 64-bit install on a
  Pi Zero 2 W. It changes boot USB gadget settings, installs systemd services,
  configures NetworkManager, and manages the PipeWire/WirePlumber Bluetooth
  playback path.
- Example Bluetooth MAC addresses in this repo are placeholders. A real
  headphone MAC is written only to the target Pi's `/etc/default/pi-audio-dongle`
  during install.
- Wi-Fi stays enabled by default so first-time SSH installs remain reachable.
  Use `DISABLE_WIFI_AFTER_INSTALL=1` only after USB Ethernet management has been
  verified.
- Live USB cutover is intentionally opt-in. Prefer rebooting after a fresh
  install; use `RESTART_GADGET_NOW=1` or `safe-usb-cutover.sh` only when you are
  prepared for the guarded rollback behavior.

## Runtime Path

1. `usb-gadget.service` creates a UAC2 audio plus CDC-ECM USB gadget.
2. The host sends USB audio to ALSA capture device `hw:UAC2Gadget,0`.
3. `camilladsp.service` applies the selected DSP preset and plays to ALSA device
   `pipewire`.
4. PipeWire/WirePlumber route audio to the Bluetooth A2DP sink.
5. `airpods-connect.service` reconnects the configured headphones and sets them
   as the default sink.
6. `usb-fallback-guard.service` restores `g_ether` if the composite gadget fails.

## Verify From A Development Machine

```bash
PI_HOST=<pi-user>@raspberrypi.local ./provision/verify-live.sh
```

## Notes

- PipeWire/WirePlumber is the intended Bluetooth audio path.
- `provision/systemd/bluealsa.service` is deprecated and kept only as a reference;
  the installer removes/disables BlueALSA runtime ownership.
- `provision/build-pipewire-aac-plugin.sh` is optional. Use it only on images
  where PipeWire lacks the AAC BlueZ codec plugin.
