<p align="center">
  <img src="docs/images/icon.png" width="160" height="160" alt="BrightBoi icon">
</p>

<h1 align="center">BrightBoi</h1>

<p align="center">
  A free, native menu bar app that unlocks your MacBook Pro's real XDR brightness headroom —
  past the ceiling Control Center normally allows.
</p>

<p align="center">
  <a href="https://github.com/joaodavidsilva/brightboi/releases/latest"><img src="https://img.shields.io/github/v/release/joaodavidsilva/brightboi?label=download&color=orange" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS%2014%2B%20%C2%B7%20Apple%20silicon-lightgrey" alt="Requires macOS 14 or later on Apple silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
  <a href="https://buymeacoffee.com/ptlghost"><img src="https://img.shields.io/badge/buy%20me%20a-coffee-ffdd00?logo=buy-me-a-coffee&logoColor=black" alt="Buy Me a Coffee"></a>
</p>

---

## What it does

Macs with a Liquid Retina XDR display (the mini-LED MacBook Pros) have real brightness
headroom that Control Center never lets you touch, and third-party apps that unlock it for
everyday use are mostly paid downloads. BrightBoi gives you that control for free, as a single
continuous slider:

- **0–200% on one slider.** 100% still means exactly what Control Center's 100% has always
  meant (about 500 nits on the 14-inch and 16-inch M1 Pro and M1 Max panels). 100–200% is
  **Extended Brightness / Boost**: a tiny invisible window keeps the display's extended
  dynamic range (EDR) headroom available, and BrightBoi scales the display's gamma table
  into it. The top of the slider is capped at about 1000 nits, the panel's sustained
  full-screen rating, not its 1600-nit peak-highlight spec that would just throttle back down
  under sustained use.
- **Auto-Brightness Takeover.** Disables macOS's ambient-light-sensor-driven auto-brightness on
  launch, so it can never silently override the level you chose.
- **5% steps** on both the slider and the physical brightness keys, so you always land on a
  clean, repeatable value.
- **Persists** your chosen level across sleep/wake, relaunch, and reboot, and **launches at
  login** so Auto-Brightness Takeover is active from the moment you log in.
- **Built-in display only** — never touches an external monitor.

Boost is only available on Macs with an XDR (mini-LED) display. On a non-XDR Apple silicon
Mac (e.g. MacBook Air), BrightBoi still works, but the slider simply caps at 100% Nominal
Brightness with no Boost UI, since the physical backlight headroom Boost relies on doesn't
exist there.

## Requirements

- An Apple silicon Mac (M1 or later) running macOS 14 (Sonoma) or later. Intel Macs are not
  supported.
- For Boost (100–200%): a MacBook Pro with a Liquid Retina XDR display.

## Install

1. Download the latest zip (`BrightBoi-<version>.zip`) from [Releases](https://github.com/joaodavidsilva/brightboi/releases/latest).
2. Unzip it and drag `BrightBoi.app` into `/Applications`.
3. **First launch:** this app isn't notarized yet (see [Known limitations](#known-limitations)
   below), so Gatekeeper blocks a plain double-click with an "unidentified developer" warning.
   - **macOS 15 and later:** double-click `BrightBoi.app`, dismiss the warning, then open
     **System Settings > Privacy & Security**, scroll to the Security section and choose
     **Open Anyway** next to BrightBoi. Confirm in the dialog that appears.
   - **macOS 14:** right-click (or Control-click) `BrightBoi.app`, choose **Open**, then
     confirm in the dialog.

   Doing this once is enough: macOS remembers your choice after that.
4. A sun icon appears in your menu bar. Click it for the brightness slider.
5. To take over the physical brightness keys (F1/F2), BrightBoi needs the **Accessibility**
   permission. Grant it in System Settings when prompted. BrightBoi picks the permission up while it
   runs; if the keys still stay with macOS, use "Relaunch BrightBoi" in Settings. The slider and
   custom shortcuts work without it.

## Updating

Quit BrightBoi (menu bar sun, then Settings > Quit), then replace `BrightBoi.app` in
`/Applications` with the new one and open it.

BrightBoi makes no network requests unless you ask it to. **Check for Updates…** in Settings
looks for a newer release on GitHub when you click it. From the second launch on, the popover
asks once whether BrightBoi may check automatically; if you say yes, it contacts github.com
(only) once a day, and you can change your mind with the "Check for updates automatically"
switch in Settings. When a newer release exists, the popover shows a row that opens its
download page.

## Known limitations

- **Hidden menu bar icon.** When the menu bar is full, macOS hides the items that don't fit,
  and on a MacBook Pro with a notch they can end up behind it. If BrightBoi's sun is missing,
  open BrightBoi again from Applications or Spotlight: it opens Settings, where you can change
  your options or quit. Quitting other menu bar apps, or switching off items in System Settings >
  Menu Bar, makes room for the icon again.
- **HDR highlights while boosted.** Boost scales the whole display, HDR video and photos
  included, so while the slider is above 100% their brightest highlights are lost. Boost is
  off at 100% and below.
- **Invert Colors.** With Invert Colors on, Boost is paused and the display stays at 100%,
  because scaling the gamma table can darken an inverted image on Apple silicon. It comes back
  when you turn Invert Colors off. Color Filters cannot be detected and are not handled.
- **One app per brightness key.** Only one app can own the brightness keys. If you also run
  MonitorControl, Lunar, BetterDisplay or BetterTouchTool with brightness-key handling on, the
  one that started last gets the keys and the other never sees them, so which one wins depends
  on launch order. When it can, BrightBoi notices a swallowed key press and says so in
  Settings, though it cannot always tell which app took it. To use both, turn off
  brightness-key handling in the other app, or turn off "Let BrightBoi own F1 / F2" in Settings.
- **Screen saver and lock screen.** Boost steps aside while the screen saver or lock screen
  covers the display, and returns when they end.
- **Not notarized.** Releases are currently signed with a development certificate and are not
  notarized by Apple, so Gatekeeper asks you to confirm the first launch (see
  [Install](#install)). Because the signing certificate will change once a Developer ID
  release ships, macOS may ask you to grant Accessibility and Input Monitoring to BrightBoi
  again after that update.

## Building from source

Runs on macOS 14 (Sonoma) or later on Apple silicon. Building requires Xcode 16 / the Swift 6
toolchain.

```bash
git clone https://github.com/joaodavidsilva/brightboi.git
cd brightboi
swift build                      # debug build
swift test                       # run the test suite
Packaging/build-app.sh           # debug bundle (com.ptlghost.BrightBoi.dev) in .build/
```

`Packaging/build-app.sh` builds the debug bundle by default. It runs as **BrightBoi Dev**
with its own settings, so it does not touch an installed BrightBoi's preferences or login
item. It goes through onboarding again, and needs its own Accessibility and Input Monitoring
grants once. `defaults delete com.ptlghost.BrightBoi.dev` resets its state without touching
the installed release. Quit the installed BrightBoi before running a local build — both drive
the same display.

`Packaging/build-app.sh release` produces the shipping identity (`com.ptlghost.BrightBoi`).
It signs with a Developer ID or Apple Development certificate when one is installed and
refuses to fall back to ad-hoc signing, which would make macOS forget permission grants on
every build. Without a certificate, set `ALLOW_ADHOC_RELEASE=1` to build an ad-hoc signed
release bundle for local use only.

CI builds and tests every push on macOS 15 (Xcode 16.4) and the newest hosted macOS with its
latest stable Xcode. macOS 14 is the minimum the app supports but is not covered by CI,
because GitHub has deprecated its macOS 14 runners.

## Support

If you find BrightBoi useful:

<p align="center">
  <a href="https://buymeacoffee.com/ptlghost">
    <img src="https://img.shields.io/badge/Buy%20me%20a-coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black" alt="Buy Me a Coffee">
  </a>
</p>

## License

[MIT](LICENSE)
