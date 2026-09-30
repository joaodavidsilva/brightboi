<!-- Reusable text for GitHub release notes. Copy the parts that apply. -->

### Updating

Quit BrightBoi first (menu bar sun, then Settings > Quit), then replace `BrightBoi.app` in
`/Applications` with the new one and open it.

### Requirements

Apple silicon Mac (M1 or later), macOS 14 or later. Boost needs a MacBook Pro with a Liquid
Retina XDR display.

### If macOS asks for Accessibility and Input Monitoring again

Include this in the notes of any release signed with a different certificate than the
previous one, for example the first Developer ID release. macOS ties these permissions to the
signing identity, so the old grants stop applying to the new build. Grant them once more:

1. Open System Settings > Privacy & Security > Accessibility, select BrightBoi and remove it
   with the minus button, then add it again (the plus button, then choose BrightBoi from
   Applications). Do the same under Input Monitoring.
2. Or reset both from Terminal, then reopen BrightBoi and grant them when asked:

   ```bash
   tccutil reset Accessibility com.ptlghost.BrightBoi
   tccutil reset ListenEvent com.ptlghost.BrightBoi
   ```
