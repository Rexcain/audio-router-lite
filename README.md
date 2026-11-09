# Audio Router Lite

English | [简体中文](README.zh-CN.md)

A lightweight native macOS app that routes live audio from any Core Audio input device to any Core Audio output device, including USB, built-in and virtual devices.

## Download

Get `Audio-Router-Lite-<version>.zip` from the [Releases](https://github.com/Rexcain/audio-router-lite/releases) page, unzip it and move **Audio Router Lite** to Applications. It runs natively on Apple Silicon and Intel Macs with macOS 15 or later.

The app is not notarized by Apple, so the first launch is blocked with a message that the developer cannot be verified. To allow it:
1. Double-click the app once and dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to "Audio Router Lite", then confirm.

Alternatively, in Terminal: `xattr -dr com.apple.quarantine "/Applications/Audio Router Lite.app"`.

## Build from source

Requires macOS 15+ and Swift 6 (Command Line Tools are enough; Xcode is not required). The script builds a universal app (Apple Silicon + Intel); use `ARCHS="arm64" ./scripts/build-app.sh` for a faster single-architecture build.

```bash
./scripts/build-app.sh            # → build/Audio Router Lite.app
open "build/Audio Router Lite.app"
```

## Using it

1. On the **Routing** page, choose a **Source** (input device and channels) and a **Destination** (output device and channels).
2. Click **Start** (⌘R). The first time, allow microphone access; macOS requires it to read any audio input.
3. On the route card, adjust **Gain** or **Mute**. **Test tone** plays a 1 kHz tone to check the output.
4. Click **Add Route** for more routes. Use **Save Preset…** to keep a setup and the **Preset** menu to load it.

Different sample rates and device clocks are handled automatically, and your routing is saved automatically.

## Tests

```bash
swift run -c release RouterTests        # 25 automated DSP/engine tests (≈3 s)
swift run -c release ardiag list        # device dump
swift run -c release ardiag level --dev "<Audio Device 1>" --seconds 10   # peak/RMS a source really delivers
# Real end-to-end through Core Audio (needs two virtual loopback devices):
swift run -c release ardiag e2e --src "<Audio Device 1>" --dst "<Audio Device 2>" --seconds 30 --mode balanced
```

`ardiag` is an internal diagnostic tool, not the product. `ardiag probe …` measures routing done by the GUI app, and `ardiag hotplug --dev …` simulates a device being unplugged and replugged.

Measured in testing: sample-rate conversion THD+N below −110 dB, frequency response flat within 0.0001 dB up to 20 kHz, bit-exact pass-through when clocks are shared, and no dropouts in a 10-minute end-to-end test through Core Audio on virtual loopback devices.

## License

Copyright © 2026 Rexcain.

Audio Router Lite is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License version 3 (or, at your option, any later version), as published by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY. See [LICENSE](LICENSE) for the full text.

## Acknowledgements

This project was developed with the assistance of [Claude Code](https://claude.com/claude-code), Anthropic's AI coding tool.
