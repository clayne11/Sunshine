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
- Optionally make it the only active display for the streaming session, using
  temporary display configuration owned by the helper.
- Target input at the current captured display, including its current logical
  bounds, instead of caching the physical display's scale or dimensions.
- Clean up on disconnect, unsuccessful launch, timeout, helper exit, and server
  termination. Helper spawning closes unrelated file descriptors so it cannot
  retain the server's listening sockets.
- Stage and install a login-session service with restart supervision and rollback.

Current Sunshine already supplies the audio, encoding, packaging, and general
streaming foundation. Lumen's separate capture/audio stack and controller driver
are deliberately outside this initial port. Add a further port only when an
observed failure and a focused test demonstrate that it is needed.

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
5. Restoration after helper and server failure, without orphaned helpers or
   listening sockets; an abandoned launch must also clean up.
6. Service restart after clean exit and crash, and startup in the user's next
   graphical login session.
7. A tested rollback to the retained runtime and configuration.

A macOS graphical LaunchAgent runs after user login. It does not provide a
streaming desktop before FileVault unlock or before a graphical session exists.
The virtual-display interface is a private macOS API, so OS updates require a
fresh lifecycle and restoration check.
