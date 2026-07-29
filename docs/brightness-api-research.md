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
   - cleared to a color value > 1.0 (e.g. `MTLClearColorMake(1.6, 1.6, 1.6, 1.0)`)

   As soon as this renders one frame, **`NSScreen.main!.maximumExtendedDynamicRangeColorComponentValue`
   jumps from `1.0` to `~3.2`** on this hardware (matches `1600/500`, the
   panel's peak-to-nominal ratio — confirmed empirically, `attempt 1` in the
   harness output, no polling loop needed past the first check).

2. **Scale the gamma table.** Capture the current transfer function with
   `CGGetDisplayTransferByTable(displayID, 256, &r, &g, &b, &count)` (public,
   documented CoreGraphics API), multiply every table entry by a `factor`,
   and push it back with `CGSetDisplayTransferByTable`. With EDR engaged,
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

- Anchor at 100% = factor `1.0` (500 nits, Nominal ceiling, matches
  CONTEXT.md and the empirical 500-nit reading).
- Anchor at 200% = factor `2.0`, deliberately **half** of the observed
  `~3.2` max EDR headroom on this panel — this is what keeps the Boost
  Ceiling at 1000 nits sustained per
  [ADR-0002](adr/0002-boost-ceiling-sustained-not-peak.md), leaving real
  margin below the 1600-nit peak headroom rather than running the gamma
  table right up against it.
- The `100–200%` factor curve is presented linear-in-factor as a starting
  point; it is **not** independently nits-verified (see caveat above), so
  treat it as a reasoned default, not a measured curve. If a manual check
  during ticket 04/05 shows it feels non-linear (perceptually or in battery
  draw), an eased curve can replace the linear one without changing the
  anchors.
- The EDR overlay window needs to be mounted whenever `percentage > 100` and
  stay mounted (BrightIntosh's `GammaTechnique.swift` handles sleep/wake,
  space changes, and periodic gamma-table-drift detection/reapplication —
  this is nontrivial recurring-maintenance logic, not a one-shot call, and
  ticket 04/05 should budget for it as part of `DisplayBrightnessProviding`,
  not treat it as a simple wrapper over a single symbol).

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
  only the two anchor points (100% = 500 nits via the independently-verified
  Nominal register, 200% = 1000 nits via the deliberate half-headroom
  choice) are grounded. Recommend a manual visual check before ticket 04/05
  ships.
- The EDR overlay must persist for the entire time the user is boosted, and
  needs sleep/wake and drift-recovery handling (see BrightIntosh's
  `GammaTechnique.swift` for the shape of that problem) — this is a bigger
  implementation surface for `DisplayBrightnessProviding` than a single
  private setter call would have been.
