# Changelog

All notable changes to BrightBoi are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

<!--
Maintainers: release notes are the matching section of this file; see the header of
Packaging/release.sh. If a release changes the signing identity, add the re-grant line from
Packaging/release-notes-snippet.md to its section.
-->

## [Unreleased]

## [1.2.0] - 2026-09-30

### Added

- The shortcut recorder in Settings accepts any key with a modifier, checks the choice against
  shortcuts macOS already uses, and shows why a combination was refused. Custom shortcuts keep
  working while Secure Keyboard Entry is on, and need no permission. A "Reset to F1/F2" button
  brings the default back.
- A "Turn off macOS auto-brightness while BrightBoi runs" switch in Settings. The original
  setting is restored when BrightBoi quits.
- "Check for Updates…" in Settings, the running version in the Settings footer, and an optional
  daily update check that asks for permission once, from the second launch on.
- "Support BrightBoi…" in Settings opens the support window at any time.
- Opening BrightBoi again while it is running opens Settings, so a menu bar icon hidden behind
  the notch can no longer lock you out.
- Permission status updates live in Settings and in the setup window, and Settings offers
  "Relaunch BrightBoi" when a newly granted permission needs it.
- A new app icon that stays readable at small sizes.
- Increase Contrast and VoiceOver support throughout the popover, Settings, setup window and
  support window.
- Debug builds run as "BrightBoi Dev" with their own settings, and BrightBoi asks before
  quitting a running copy of the other identity.

### Changed

- The brightness key meter shows on the built-in display wherever keyboard focus is, with a
  percentage readout, a spoken level for VoiceOver, and a fade that respects Reduce Motion.
- BrightBoi now starts at the display's current brightness instead of overwriting it, and
  follows changes made elsewhere, such as Control Center.
- Settings is a native grouped form. The popover slider, range captions, advisory banners and
  menu bar icon were redrawn: the icon now shows the level and a Boost badge, and information
  that does not need action is no longer shown in amber.
- The support window appears a week after you first start BrightBoi and then at most once a
  month, never over the setup window and never when BrightBoi was only started by logging in.
  It no longer takes focus from the app you are using.
- Closing the setup window counts as finishing it, and "Skip — slider only" moves on to the last
  step instead of closing the window.
- Boost follows the built-in display: it survives display sleep, wake, display changes,
  profile changes and another process writing the gamma table, steps aside for the screen saver
  and the lock screen, and pauses while Invert Colors is on.
- The Boost ceiling adapts to the panel's own headroom, so panels with a brighter normal
  range get a lower 200% instead of clipping.
- When the built-in display is off, BrightBoi leaves the brightness keys to macOS.

### Fixed

- Granting Accessibility while BrightBoi is running now takes over the brightness keys without a
  relaunch.
- BrightBoi no longer swallows keys that are not brightness keys, and brightness keys pressed
  with Command, Control or Option alone go to macOS as usual.
- BrightBoi says so when another app takes the brightness keys first.
- macOS auto-brightness is restored when BrightBoi quits, when it was on to begin with.
- Boost no longer gets stuck when a pause outlives its cause.
- Launch at login explains what is needed when macOS wants approval.
- Release builds are built against the current macOS SDK, so controls on macOS 26 and later
  look current.

## [1.1.0] - 2026-08-02

### Changed

- The minimum supported macOS is now 14 (Sonoma), down from the exact macOS build BrightBoi was
  developed on. There are no other changes.

## [1.0.0] - 2026-08-01

A complete overhaul since 0.1.0.

### Added

- A redesigned popover and menu bar icon.
- A Settings window with an adjustable Boost ceiling and a configurable Key Remap.
- An on-screen HUD for the brightness keys.
- First-run setup that replaces the blocking permissions alert.
- Battery and heat advisories in the popover.
- A support window.
- A Launch at login switch and a Quit button.

### Fixed

- F1 and F2 now work as brightness keys. Releases are signed with an Apple Development
  certificate instead of ad-hoc, which lets macOS keep the Accessibility and Input Monitoring
  grants. Upgrading from 0.1.0 needs both granted again, because the signing identity changed.

## [0.1.0] - 2026-07-30

First public build.

### Added

- One slider from 0 to 200%: 0-100% is the normal brightness range and 100-200% is Boost on
  Liquid Retina XDR MacBook Pros.
- Brightness moves in 5% steps, and the level is remembered across sleep, relaunch and reboot.
- macOS auto-brightness is turned off while BrightBoi runs.
- Launch at login, and an experimental remap of the F1/F2 brightness keys.
