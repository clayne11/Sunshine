# Maintaining the macOS virtual-display fork

This fork starts from official Sunshine tag `v2026.906.222525`
(`cb72dffa3233c5815cd5ba88f09f049dd679ba75`). Its upstream history is retained.
The macOS virtual-display work is a small, optional layer above that baseline.

## Scope and origin

The display helper/controller was adapted from the retained Lumen source
(`5c3bd0f4109eb4069d10ee1a8201b9bf3a328018`, originally `trollzem/Lumen`).
The original Lumen tree and local additions were preserved separately before
starting this fork. Existing copyright and license terms remain applicable.

Retained capabilities:

- Create a macOS virtual display matching the connecting client's requested mode.
- Create the virtual display before the first-session encoder probe so a headless
  or temporarily inactive physical desktop can bootstrap its capture target. A
  live Sunshine-owned virtual display may proceed when the parent process cannot
  read its current CoreGraphics mode; capture initialization remains the final
  readiness check.
- Use ScreenCaptureKit for video capture of session-owned virtual displays on macOS
  12.3 and later, resolving the current display again when a stream starts after
  recreation. Host audio uses Sunshine's native capture path.
- Optionally make it the only active display for the streaming session, using
  temporary display configuration owned by the helper.
- Target input at the current captured display, including its current logical
  bounds, instead of caching the physical display's scale or dimensions.
- Persist a virtual-display mode changed in macOS Displays under the paired
  client's certificate fingerprint and requested width and height. Each client
  resolution has an independent mapping. A matching reconnect restores logical
  and backing-pixel dimensions while using the connection's current refresh rate.
  Legacy single-entry files remain readable for their matching client resolution.
  The virtual monitor serial uses the same client-resolution identity. Process
  AppKit events to keep mode snapshots current, and reapply the requested mode
  after WindowServer restores any remembered monitor state during startup. Observe
  full mode changes while the display is live and save each dimension or HiDPI
  change, including a return to the initial mode; refresh-only changes do not
  create a resolution preference. A final snapshot preserves any pending save.
  Requests from another paired client or for another tuple never inherit the
  live display; they retry after its current session has finished.
- Keep the `CGVirtualDisplay` lifecycle in a dedicated helper. Private hardware
  enablement targets physical displays only. Normal shutdown restores them
  before releasing the virtual display; a surviving supervisor also restores
  them after a holder crash. App-only scope does not provide automatic crash
  restoration. Helper spawning
  closes unrelated file descriptors so it cannot retain the server's listening
  sockets.
- Exclude the observed macOS fallback and stale Sunshine virtual-display
  signatures from saved physical-display snapshots. WindowServer may replace
  those IDs during headless startup, making them invalid hardware enablement
  targets. Skip exclusive configuration only when the requested display is
  already the exact sole active display; other active displays still prevent
  success. An empty physical baseline needs no restoration transaction.
- Hold independent display-sleep prevention assertions in the virtual-display
  supervisor and holder throughout exclusive setup and restoration. Before the
  supervisor snapshots physical displays, declare remote user activity and
  wait up to 500 milliseconds for an ordinary display to reappear; continue
  after the bound so genuinely headless hosts remain supported.
- Use the supervisor/holder pair to recover when either process dies alone.
  The supervisor has its own process group so launchd can restart Sunshine
  without killing display recovery. Recovery after both helper processes die
  together is not a tested guarantee.
- Stage and install a login-session service with restart supervision and rollback.

Current upstream Sunshine already supplies the audio, encoding, packaging, and
general streaming foundation. This selective port adds virtual-display video
capture through ScreenCaptureKit on macOS 12.3 and later; Lumen's separate
audio stack and controller driver remain outside the port. Add a further port
only when an observed failure and a focused test demonstrate that it is needed.

## Optional remote microphone

The macOS receiver supports VoidLink's encrypted microphone extension and sends
received voice to an explicitly selected Core Audio output UID. A virtual device
such as Loopback Pass-Thru or BlackHole makes it available as a Mac microphone.
No vendor SDK or driver is bundled. Global host-audio taps exclude Sunshine's own
output; the microphone sink remains silent until that exclusion is active.
See [setup and release checks](remote-microphone.md). Keep the receiver and
routing changes separate from display lifecycle patches when taking upstream updates.

## Input dependency

The `third-party/libvirtualhid` submodule has a companion patch in
[clayne11/libvirtualhid](https://github.com/clayne11/libvirtualhid). It adds a
validated per-event pointer viewport, consumed by the macOS backend, without
mutable process-wide target state. The baseline is official commit
`6fdb8bd4de3b68d96c30e5303ac2ebb333c09746`.

Publish dependency commits before updating Sunshine's submodule pointer. Keep
that patch separate from the display lifecycle and service changes. If an
upstream release provides equivalent targeting, migrate to its supported API
and remove the dependency patch after regression tests pass.

## Taking upstream updates

Keep `upstream` pointed at `LizardByte/Sunshine`, and keep the default branch free
of local feature changes. Fetch upstream tags and choose a stable release. Create
a new integration branch from the feature branch, then rebase the local commits
onto that release. Do not rewrite the deployed branch or delete the prior
working build while validating an update.

For each update, compare the upstream macOS display, capture, input, audio,
launch/resume, and session teardown changes with this patch set. Drop a local
patch only after checking both equivalent behavior and the regressions it
protects. Update the companion library against the dependency version selected
by Sunshine; do not independently upgrade unrelated dependencies.

Build in a `cmake-build-` directory, as required by this repository. Run the
focused virtual-display, pointer geometry, helper-spawn, configuration, and
locale tests, plus the library's pointer/runtime tests. Build the web interface.
Tests that post real desktop input must run only in an explicitly controlled
interactive test session.

## Staging and release gate

Use separate runtime, assets, configuration, state, logs, certificates, and
ports. Disable UPnP for staging. Do not copy the old Lumen mirror prep commands
into the new configuration. The new helper does not use the old global display
ID file or layout monitor. See `scripts/macos-service/README.md` for staging and
rollback mechanics.

Compilation and unit tests do not establish end-to-end readiness. Before
switching the installed service, record successful checks for:

1. Client-requested resolution and refresh rate, including the iPad Pro 11-inch
   M4's 2420 by 1668 mode.
2. Video and system audio; absolute touch and relative pointer reaching all
   edges; clicks and dragging after a physical/virtual scaling change.
3. Repeated disconnect, reconnect, resume, and changed client resolution.
4. Exclusive mode exposing only the virtual display while connected, followed
   by restoration of the original physical display arrangement on disconnect.
5. Explicit restoration after helper or server failure, without orphaned
   helpers or listening sockets; verify supervisor/holder recovery when either
   process dies alone. Treat simultaneous failure as untested until it is
   exercised.
6. Service restart after clean exit and crash, and startup in the user's next
   graphical login session.
7. A tested rollback to the retained runtime and configuration.

A macOS graphical LaunchAgent runs after user login. It does not provide a
streaming desktop before FileVault unlock or before a graphical session exists.
The virtual-display interface is a private macOS API, so OS updates require a
fresh lifecycle and restoration check.
