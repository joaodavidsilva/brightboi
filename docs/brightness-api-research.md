# Brightness API research (ticket 02)

Empirical findings for how `BrightnessController`'s real (non-fake)
`DisplayBrightnessProviding` implementation should talk to the display, per
[spec](../.scratch/brightboi/spec.md) and [CONTEXT.md](../CONTEXT.md)'s
Nominal Brightness / Extended Brightness / Boost Ceiling vocabulary.

All testing below was done on the actual target machine (MacBook Pro M1 Max,
Liquid Retina XDR, macOS 27.0 build 26A5388g) using a throwaway harness, not
shipped code — see `.scratch/brightboi/research/`. That directory is
reproducible scratch work, not part of the app; nothing in `Sources/` depends
on it. Raw captured output from every run referenced below is in
`.scratch/brightboi/research/run-log.txt`.

## Summary

- **Nominal Brightness (0–100%)** is unlocked by `DisplayServices.framework`
  — a private but widely-used, well-behaved framework. Confirmed working.
- **Extended Brightness / Boost (100–200%)** is **not** achieved by handing an
  out-of-range value to a private "set brightness" symbol, contrary to what
  the ticket assumed. The mechanism that actually moves the panel past the
  Nominal ceiling is a **public-API technique**: force EDR (Extended Dynamic
  Range) engagement with a tiny always-on-top Metal overlay, then scale the
  display's gamma/transfer table past 1.0 with `CGSetDisplayTransferByTable`.
  Confirmed working. **This contradicts a premise in [ADR-0001](adr/0001-private-apis-force-direct-distribution.md)** — see [Flag for the user](#flag-for-the-user-adr-0001-premise) below.
- A private low-level candidate (`CoreDisplay_Display_SetUserBrightness` with
  values > 1.0) was tested and found **unreliable** on this hardware/OS — a
  legitimate negative result, consistent with community reports that it
  doesn't work on Apple Silicon.

## Nominal Brightness (0–100%): `DisplayServices.framework`

```swift
// dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
// dlsym: "DisplayServicesGetBrightness", "DisplayServicesSetBrightness"
```

- **Value type/range:** `Float`, `0.0...1.0`. This is the exact value Control
  Center's own slider reads and writes — no translation needed.
- **Confirmed working:** `DisplayServicesGetBrightness` read back `1.0` at
  full brightness; setting `0.5` was accepted (`result == 0`) and the panel's
  own physical-brightness counter (see next section) read back as a lower,
  non-linear-but-monotonic value, consistent with macOS's native brightness
  curve.
- **Mapping:** none needed. `percentage ∈ [0, 100] → DisplayServicesSetBrightness(displayID, Float(percentage / 100.0))`.
  This is exactly what Control Center has always done, satisfying spec item
  20 (dragging below 100% behaves exactly like the old slider) for free.

## Ground-truth signal used for verification: `IOMFBBrightnessLevel`

No photometer was available, so verification leaned on an IORegistry counter
discovered on the `AppleCLCD2` node (the DCP driver backing the built-in
panel, matched via `IONameMatch = disp0,t600x` for the M1 Max):

```
ioreg -lw0 -r -c AppleCLCD2
```

- `limit_max_physical_brightness = 104857600` = `1600 × 65536` exactly — the
  panel's peak spec, encoded **Q16.16 fixed-point nits**.
- `IOMFBBrightnessLevel = 32767996` ≈ `500 × 65536` (`499.99` nits) when
  `DisplayServicesGetBrightness` read `1.0`. This is a precise, independent
  confirmation that Nominal 100% really is 500 nits, matching CONTEXT.md.

This register is a solid proxy for the Nominal range (0–100%), where it
tracks 1:1 with the panel's actual driven brightness. **It stopped being a
useful proxy once EDR was engaged** — see caveat below. Ticket 04/05 can
reuse this read-only technique (shell out to `ioreg`, or use
`IORegistryEntryCreateCFProperties` directly) for manual/diagnostic
verification, but should not build production logic on top of an
undocumented registry key.

## Extended Brightness / Boost (100–200%): EDR trigger + gamma table

### What did *not* reliably work

`CoreDisplay.framework`'s `CoreDisplay_Display_SetUserBrightness(CGDirectDisplayID, Double) -> Int32`
(exported since macOS 10.12.4, used by older Lunar/BetterDisplay-adjacent
tooling) was dlsym'd and called with values from `1.1` to `2.0`. One early
call (`1.2`) appeared to move `IOMFBBrightnessLevel` to ~600 nits, but this
did **not** reproduce under a controlled re-test (fresh baseline, longer
settle time, repeated reads): every value from `1.0` through `2.0` read back
as exactly 500 nits. `CoreDisplay_Display_GetUserBrightness` also never
reported anything above `1.0` regardless of what was set. Conclusion: this
symbol does not reliably control the panel past Nominal on this Apple
Silicon Mac / macOS 27 — matches independent reports (Alin Panaitiu/Lunar's
["Trying to get past the 500 nits limit… (and failing)"](https://alinpanaitiu.com/blog/over-500nits-failed/)
blog post) that this class of API is unreliable or non-functional on Apple
Silicon.

### What did work

This matches the technique used by [BrightIntosh](https://github.com/niklasr22/BrightIntosh)
(open source, GPLv3 — **do not copy its code into `Sources/`**; reimplement
from the technique description below) and referenced by BetterDisplay's wiki
as "special hacks and undocumented APIs" for native XDR upscaling on
built-in displays:

1. **Trigger EDR system-wide.** Create a 1×1px, borderless,
   always-on-top (`.screenSaver` level), transparent `NSWindow` whose content
   view is an `MTKView`/`CAMetalLayer` with:
   - `colorPixelFormat = .rgba16Float`
   - `colorspace = CGColorSpace(name: .extendedLinearSRGB)`
   - `layer.wantsExtendedDynamicRangeContent = true`

   The EDR request is the layer's `wantsExtendedDynamicRangeContent` flag,
   together with a frame actually presented to the window server. Pixel
   values above 1.0 are not what triggers it: a fully transparent frame
   engages the same headroom on macOS 27. BrightBoi presents a
   near-invisible premultiplied value (`MTLClearColorMake(0.016, 0.016,
   0.016, 0.01)`) rather than a fully transparent one only so that no
   compositor has grounds to skip an empty layer; it has not been verified on
   every supported macOS version whether transparent is safe everywhere.

   As soon as this renders one frame, **`NSScreen.main!.maximumExtendedDynamicRangeColorComponentValue`
   climbs from `1.0` to `~3.2`** on this hardware (matches `1600/500`, the
   panel's peak-to-nominal ratio), over roughly half a second to a second.
   Gamma scaling must follow that ramp rather than run ahead of it, or the
   highlights clip. The property that says whether a panel *can* boost at all
   is `maximumPotentialExtendedDynamicRangeColorComponentValue` (`16.0` on
   the XDR panel): the current value stays at `1.0` until something asks for
   EDR, so it can't be used to detect support.

2. **Scale the gamma table.** Capture the current transfer function with
   `CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &count)`
   (public, documented CoreGraphics API; the built-in panel's table has 1024
   samples, see `CGDisplayGammaTableCapacity`), multiply every table entry by
   a `factor`, and push it back with `CGSetDisplayTransferByTable`. The
   read-back never reports a sample above `1.0`: a scaled table reads back
   clamped, so a scaled table shows as a plateau at the top of the range
   rather than as a peak above identity. With EDR engaged,
   factors > 1.0 no longer clamp at white — they render into the unlocked
   headroom, which is what makes ordinary SDR desktop content appear
   brighter **system-wide** (not just inside the triggering app's own
   window). All 9 factors tested (`1.0` through `3.0`) returned
   `kCGErrorSuccess` (`0`).

3. **Clean up.** Reapply the originally-captured table and call
   `CGDisplayRestoreColorSyncSettings()`, then close the overlay window.
   Confirmed this restores exactly to baseline (`IOMFBBrightnessLevel` back
   to `32767996`, `DisplayServicesGetBrightness` unaffected throughout at
   `1.0`) — the two mechanisms are orthogonal, so Nominal (<100%) and Boost
   (>100%) can coexist without fighting each other.

### Caveat: the nits-readback proxy breaks down here

Once EDR was triggered, `IOMFBBrightnessLevel` immediately jumped to
`~1597 nits` (essentially the 1600-nit peak) **regardless of gamma factor**
— it did not move between factor `1.0` and factor `3.0`. This means the
register reflects the panel's *available driving headroom* once EDR is
requested, not the *actual rendered luminance* of on-screen content (which
is what the gamma factor controls). In other words: triggering EDR alone
does not make anything look brighter and should not, by itself, draw more
power/heat than baseline — the gamma factor is what actually pushes
real content into that headroom, and there is no cheap IORegistry counter
that reflects it. **No photometer was available in this environment to
measure the resulting nits directly against the gamma factor.**
Ticket 04/05 should do a manual/visual sanity check when implementing the
real `DisplayBrightnessProviding`, and adjust the factor curve below if it
looks over- or under-driven.

## Percentage → API-value mapping

| BrightBoi % | Mechanism | Call |
|---|---|---|
| 0–100% | Nominal (DisplayServices) | `DisplayServicesSetBrightness(id, Float(pct / 100.0))` |
| 100% (exact boundary) | Boost technique disengaged | no EDR overlay / gamma table left at identity |
| 100–200% | Boost (EDR trigger + gamma) | overlay window mounted; `factor = 1.0 + (pct - 100) / 100.0`, clamped `[1.0, 2.0]` |

- Anchor at 100% = factor `1.0` (the Nominal ceiling; 500 nits on the M1 Pro
  and M1 Max panels this was measured on, matching the empirical 500-nit
  reading). Other XDR panels have a different SDR white (Apple rates later
  generations at 600 nits), so 500 nits is a figure for this panel, not for
  every XDR panel.
- Anchor at 200% = a luminance ratio of `2.0` on this panel, which is
  62.5% of the observed `~3.2` peak-to-Nominal headroom (not half of it:
  half would be 1.6). This keeps the ceiling at the panel's 1000-nit
  sustained rating rather than running the gamma table up against the
  1600-nit peak. The rule is per panel: the ceiling ratio is
  `min(2.0, 0.625 × H)`, where `H` is the largest *unthrottled* EDR headroom
  seen at Nominal 100% (1000 nits divided by the panel's own SDR white). It
  is 2.0 where `H` is about 3.2 and about 1.67 on a 600-nit panel
  (`H` of about 2.67). BrightBoi learns `H` while Boost runs, counting a
  reading only once it has held steady (the headroom passes through larger
  values while the backlight ramps and smaller ones when throttled), and
  stores it per display, so the ceiling is right from the next launch on.
  Until it is known the full 2.0 applies, and the live clamp to the granted
  headroom prevents clipping.
- The `100–200%` curve is linear in the luminance ratio as a starting
  point (`BoostCurve.linear`; a geometric, equal-ratio alternative exists and
  is switched by changing `BoostCurve.active`); it is **not** independently nits-verified (see caveat above), so
  treat it as a reasoned default, not a measured curve. If a manual check
  in use shows it feels non-linear (perceptually or in battery
  draw), an eased curve can replace the linear one without changing the
  anchors.
- The EDR overlay window needs to be mounted whenever `percentage > 100` and
  stay mounted. Keeping Boost alive is recurring maintenance, not a one-shot
  call; see [Keeping Boost alive](#keeping-boost-alive).

## Keeping Boost alive

Boost is undone by events that replace the display's table or cover the
overlay. `BoostEngagement` handles them as follows.

**Events that reset or replace the table.** Display-only sleep and wake
(`NSWorkspace.screensDidWakeNotification`; a display-only wake does not post
`didWakeNotification`), system wake, a display reconfiguration
(`CGDisplayRegisterReconfigurationCallback`, completed notifications only),
a session becoming active again, a change of the display's ColorSync profile
(the distributed notifications `com.apple.ColorSync.DeviceProfilesNotification`
and `com.apple.ColorSync.DisplayProfileNotification`, the values of the
exported `kColorSyncDeviceProfilesNotification` and
`kColorSyncDisplayDeviceProfilesNotification`), and another process writing
the table. Each re-validates at once and again after 0.5 s and 2 s. The live
table is compared with what was last written: still ours, keep the baseline;
a plain table, adopt it as the new baseline (so a changed profile survives a
later disengage); anything else (samples at the top of the range, a
non-monotonic curve), leave it alone. A read-back never reports a sample above
1.0, so a boosted table is recognised by a plateau at the top rather than by
a peak, and nothing is ever compared by exact equality. The ColorSync
notification names are confirmed as exported constants on macOS 27; that they
are posted on an actual profile change has not been observed.

**Events that cover the overlay.** WindowServer takes the EDR headroom back
about 15 s after something opaque covers the overlay's pixel: the screen saver,
the lock screen (loginwindow's shield windows), another user's session, and
apps that capture the display (`CGShieldingWindowLevel` is far above the
overlay's `.screenSaver` level). The overlay must not be raised above
`.screenSaver`, which would keep the panel in EDR behind the screen saver.
Instead Boost is *suspended* for the duration: the unscaled baseline is written
and EDR released, and Boost resumes only when no reason remains (so the screen
saver ending while the screen is still locked does not resume). The signals
are the distributed notifications `com.apple.screensaver.didstart`/`didstop`
and `com.apple.screenIsLocked`/`screenIsUnlocked`, and
`NSWorkspace.sessionDidResignActive`/`BecomeActive`. A missed notification is
repaired by reading the session back (`CGSessionCopyCurrentDictionary`'s lock
and console keys, and whether `com.apple.ScreenSaver.Engine` is running) on
each re-validation and each engagement. As a fallback, an overlay whose
occlusion state loses `.visible` is ordered to the front once, and Boost is
suspended if it is still covered 0.5 s later. Headroom that stays below 1.05
for 2.5 s with Boost wanted gets the overlay asked for EDR again, at most every
5 s. While the factor follows the granted headroom (polled every 0.25 s), a
resumed Boost never clips: it comes back as the headroom returns.

A closed lid (the built-in display online but not active) is a suspension
reason too, and nothing is written to the dark panel.

**Invert Colors.** On Apple silicon the transfer table is reported to be
applied before the system's invert stage, so scaling the table with Invert on
would darken the image instead of brightening it. The ordering has not been
confirmed on macOS 27 hardware; to be safe Boost is paused while
`accessibilityDisplayShouldInvertColors` is true and the display stays at
Nominal 100%. Color Filters have no public signal.

**HDR.** Boost writes a display-wide table, so HDR highlights are expected to
collapse to about the boosted SDR white while it is on (reports from other apps
using the technique). This is disclosed in the popover and README. Whether a
table BrightBoi has written once keeps HDR clipped after returning to 100% is
unchecked; if it does, `disengage()` should call
`CGDisplayRestoreColorSyncSettings()` when the built-in is the only active
display.

## Calibrating the Boost factor

Two questions need eyes, not a photometer, because no luminance readback
exists once EDR is engaged.

1. **Does the table scale linear light or the encoded signal?** `GammaDomain`
   assumes linear. Run `swift Tools/gamma-domain-calibration.swift` with
   Nominal brightness at 100%, Night Shift and True Tone off. It covers the
   built-in display with a 0-255 step wedge and engages EDR; raise the factor
   with the arrow keys until the brightest steps merge, keeping each trial to a
   few seconds (the tool drops back to 1.0 after 6 s and restores the table on
   every exit; the tool has been typechecked but not yet run on a panel, so watch the first launch and press Esc to leave). Merging near the headroom (about 3.2) means linear light;
   merging near 1.70 (the headroom to the power 1/2.2) means gamma-encoded. To
   apply the result, set `GammaDomain.assumed` to `.encoded(gamma: 2.2)`; the
   factor mapping and the headroom clamp both follow.
2. **Does 200% clip?** At 200% (factor 2.0 on an M1-class panel) the wedge must
   show no merged top steps.

Record the result here with the macOS build. Not yet measured.


## Auto-Brightness Takeover (ticket 06): `CoreBrightness.framework`'s `CBALC*`

Ticket 02 (above) didn't research this — it's ticket 06's concern. Findings
below are from ticket 06's own small spike
(`.scratch/brightboi/research/auto-brightness-spike.swift`, raw output in
`run-log.txt`), same target machine.

- **Dead end:** `DisplayServices.framework` exports
  `DisplayServicesAmbientLightCompensationEnabled` /
  `DisplayServicesEnableAmbientLightCompensation` — both resolve via
  `dlsym`, but toggling one changed neither its own getter nor
  `system_profiler SPDisplaysDataType`'s "Automatically Adjust Brightness"
  field. A symbol resolving is not evidence it does what its name implies;
  this is very likely a color/TrueTone-adjacent ambient compensation, not
  the brightness auto-adjust toggle. Abandoned.
- **Confirmed working:** `CoreBrightness.framework` exports
  `CBALCGetDisplayAutoBrightnessEnabled() -> Bool` and
  `CBALCSetDisplayAutoBrightnessEnabled(Bool) -> Void` ("ALC" = Ambient
  Light Client). Found via `dyld_info -exports CoreBrightness.framework`
  (grep for `auto`/`ambient`) rather than guess-a-name-then-`dlsym`, since
  `dlsym` can't enumerate a framework's exports and nobody would guess this
  name unprompted — `otool`/`nm` can't read the file either, since on this
  OS it's a broken symlink into the dyld shared cache; `dyld_info` reads
  the export trie directly and does resolve through the cache.
- Calling the setter flips `defaults read com.apple.CoreBrightness`'s
  `"Automatic Display Enabled"` key in both directions, and that same key
  is confirmed to be what System Settings' own checkbox writes (verified by
  force-quitting System Settings, performing a real click on Displays >
  "Ajustar brilho automaticamente", and re-reading the preference).
  `log show --predicate 'process == "corebrightnessd"'` during a call shows
  the real root daemon (PID matches `ps aux | grep corebrightnessd`)
  processing it — a `DisplayBrightnessAuto` key changing and
  `CBRampManager`/`SDR_RAMP` activity — not just a local plist write with no
  live effect.
- **Caveat, not fully resolved:** System Settings' Displays pane sometimes
  did not visually refresh its checkbox after a raw `CBALCSet` call, even
  after a full quit+relaunch of the pane — only a real user click resynced
  its view. The daemon-log evidence above indicates the underlying setting
  did change regardless; this looks like the Settings extension not
  observing a live notification our one-shot, unentitled CLI process
  doesn't send, rather than the preference write being inert. Flagged
  rather than guessed further — worth a fresh look if a user report says
  the Settings checkbox looks stale after BrightBoi disables the setting.
- **Reliability note:** calling the getter twice in the same process in
  quick succession (immediately after a `set`) crashed with `SIGSEGV`
  inside `CBALCGetBoolPreferenceForKey` on both tries; the getter alone as
  the only call in a fresh process succeeded on every try (6+). This
  matches `BrightnessController`'s actual usage shape — one
  `disableAutoBrightness()` call, once, at controller init, no read-back —
  not the crashing one, so the real implementation only calls the setter.

## Flag for the user: ADR-0001 premise

[ADR-0001](adr/0001-private-apis-force-direct-distribution.md) states:

> There is no public macOS API to push the built-in display's brightness
> past the Nominal Brightness ceiling... BrightBoi will use private/
> undocumented Apple frameworks... Because App Store review disallows
> private API usage, this decision forces BrightBoi to ship as a
> Developer-ID-signed, notarized app distributed directly.

This spike's confirmed-working mechanism (EDR trigger + gamma table) uses
only **public, documented** APIs (`CAMetalLayer.wantsExtendedDynamicRangeContent`,
`NSScreen.maximumExtendedDynamicRangeColorComponentValue`,
`CGGetDisplayTransferByTable`/`CGSetDisplayTransferByTable`) — combined in an
undocumented *way*, not via a private symbol. Notably, BrightIntosh (which
uses this exact technique) is distributed on the Mac App Store today. This
doesn't necessarily invalidate ADR-0001's conclusion (App Store review is
subjective and could still reject this as against the spirit of the
guidelines, and the ADR may have other standing reasons for direct
distribution), but the ADR's stated *justification* — "no public API
exists" — is empirically not accurate. Surfacing this rather than silently
building around it; whether to revisit ADR-0001 is the user's call.

Same staleness applies to CONTEXT.md's "Extended Brightness / Boost" glossary
entry ("unlocked via private Apple APIs") — noted here rather than edited
directly, since updating the domain glossary is `/domain-modeling`'s job, not
this ticket's.

## Risks / caveats

- Every mechanism here is undocumented *behavior*, even where the
  individual API calls are public — Apple can change EDR-triggering
  behavior, gamma table semantics, or `IOMFBBrightnessLevel`'s meaning in
  any macOS update. This is accepted per ADR-0001 as inherent to the
  feature.
- `CoreDisplay_Display_SetUserBrightness` was tested and found unreliable —
  don't resurrect it for the real implementation without new evidence.
- The `IOMFBBrightnessLevel`/`AppleCLCD2` IORegistry keys are internal DCP
  driver counters, not a public API — fine for manual verification, risky
  to hard-depend on in shipped code.
- BrightIntosh's source is GPLv3; it was read for research but not copied.
  Ticket 04/05's implementation must be an independent reimplementation of
  the technique described above, not a port of their code.
- No photometer was available to verify absolute nits for the Boost range;
  only the Nominal anchor (100% = 500 nits on this panel, via the
  independently-verified Nominal register) is grounded. The 200% anchor rests
  on the linear-table assumption until the step-wedge check in
  [Calibrating the Boost factor](#calibrating-the-boost-factor) is done.
- The EDR overlay must persist for the entire time the user is boosted, and
  needs wake, reconfiguration and cover handling; see
  [Keeping Boost alive](#keeping-boost-alive).
