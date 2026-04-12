# Test Harness — Pre-App-Store Removal Guide

Everything listed below is development/testing infrastructure. Most is
compiled out of release builds via `#if DEBUG`. The few non-gated items
are marked and should be reviewed before the final App Store submission.

## Files to DELETE entirely

These are test-only and have no production purpose:

| File | What it does |
|------|-------------|
| `test_shield_cycle.sh` | Shell harness script (repo root, never bundled in .app) |
| `BigBrotherApp/Services/TestCommandReceiver.swift` | Main-app Darwin observer for fg test commands (`#if DEBUG`) |
| `BigBrotherApp/Services/ParentTestCommandReceiver.swift` | Parent-app Darwin observer for production-path test commands (`#if DEBUG`) |
| `BigBrotherTunnel/TunnelTestCommandReceiver.swift` | Tunnel Darwin observer for bg test commands (`#if DEBUG`) |

## Code blocks to REMOVE from existing files

### `BigBrotherApp/App/BigBrotherApp.swift` — setupOnLaunch()

Remove the `#if DEBUG` block (~10 lines) that installs `TestCommandReceiver`
and `ParentTestCommandReceiver`:

```swift
#if DEBUG
TestCommandReceiver.install(appState: appState)
if appState.deviceRole == .parent {
    ParentTestCommandReceiver.install(appState: appState)
}
#endif
```

### `BigBrotherTunnel/PacketTunnelProvider.swift` — startTunnel()

Remove the `#if DEBUG` block (~5 lines) that installs
`TunnelTestCommandReceiver`:

```swift
#if DEBUG
if let self {
    TunnelTestCommandReceiver.install(provider: self)
}
#endif
```

### `BigBrotherTunnel/PacketTunnelProvider.swift` — handleTunnelTestNotification()

The entire `func handleTunnelTestNotification(...)` method (~100 lines) is
inside `#if DEBUG`. Remove it.

### `BigBrotherTunnel/PacketTunnelProvider.swift` — VPN recovery hooks

Inside `handleTunnelTestNotification`, the `recoverReapply` and
`recoverStaleTransport` cases are `#if DEBUG`. They go away with the
function above.

### `BigBrotherShield/BigBrotherShieldExtension.swift` — logShieldRender()

The body of `logShieldRender(application:viaCategory:)` is inside
`#if DEBUG`. The method signature and calls from `configuration(shielding:)`
can stay (they're no-ops in release) or be removed for cleanliness. The
`shieldRenderLog` UserDefaults key is only written in DEBUG.

### `BigBrotherTunnel/PacketTunnelProvider.swift` — diagnostic JSON

In `sendHeartbeatFromTunnel`, the `"shieldRenders"` and
`"monitorConfirmedAt"` fields in `tunnelDiagJSON` are harmless (they read
App Group keys that are empty in release) but can be removed for a cleaner
heartbeat payload.

## Non-DEBUG items to REVIEW

These ship in release builds. They're NOT test infrastructure but were
added alongside the harness work. Decide whether to keep:

| Item | File | Purpose | Keep? |
|------|------|---------|-------|
| `markUpstreamUnhealthy()` changed from `private` to `func` | `DNSProxy.swift:150` | Exposed for recovery hook. Harmless as internal — only the tunnel target links DNSProxy. | Probably keep |
| `monitorConfirmedAt` in diagnostic JSON | `PacketTunnelProvider.swift` | Useful for parent dashboard debugging even in prod. Zero cost (reads one double). | Keep |
| `shieldRenders` in diagnostic JSON | `PacketTunnelProvider.swift` | Array is always empty in release (writer is `#if DEBUG`). Sends `[]` — 2 bytes of JSON. | Keep or remove |
| `logShieldRender()` calls in ShieldExtension | `BigBrotherShieldExtension.swift:16,26` | Method body is `#if DEBUG`. Calls are no-ops in release. | Keep (clean) or remove calls too |

## Registry entries to CLEAN UP

Both `deploy_everywhere.sh` and `test_shield_cycle.sh` have device
registries that must stay in sync. Neither file ships in the .app bundle
— they're repo-root scripts. No cleanup needed for App Store, but if you
delete `test_shield_cycle.sh`, the duplicate registry in
`deploy_everywhere.sh` becomes the sole source.

## How to verify removal is complete

After removing the above:

```bash
grep -rn "TestCommandReceiver\|shieldRenderLog\|parenttest\|test\.bg\.\|test\.setMode" \
    BigBrotherApp BigBrotherTunnel BigBrotherShield BigBrotherMonitor \
    --include="*.swift" | grep -v "^Binary"
```

Should return zero results. Then build release:

```bash
xcodebuild -scheme BigBrother -configuration Release \
    -destination 'generic/platform=iOS' build
```
