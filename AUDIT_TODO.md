# Big.Brother Enforcement Audit — Consolidated TODO

> Merged from: Apr 3 audit (b291), b351-b363 session, tunnel DNS audit, post-update audit,
> plus full codebase audit Apr 9 (b385-396) by Claude/Codex/Gemini + deep research.
>
> Legend: [FIXED] done, [OPEN] still needs work

---

## Root Causes Identified (Deep Research, Apr 9)

| # | Root Cause | Fix |
|---|-----------|-----|
| RC1 | Tunnel heartbeat cold-start: `tunnelOwnsHeartbeat` never set when tunnel starts with dead app | FIXED b396 |
| RC2 | Silent CloudKit error swallowing in `pollAndProcessCommands()` | FIXED b396 |
| RC3 | Nuclear reset from background destroys Monitor's shields | FIXED b394 (app), b396 (AppDelegate) |
| RC4 | CloudKit record ownership after Apple ID change | Handled by existing delete+recreate logic |
| RC5 | Schedule `lockedMode` is `.unlocked` (data bug) | FIXED b396 (safety net: unlocked → restricted) |
| RC6 | FC auth write requirement — ManagedSettings no-op without auth | Platform limitation, no code fix |
| RC7 | DNS proxy readLoop death on blackhole transition | FIXED b396 |
| RC8 | Unstructured Task accumulation in tunnel timer | FIXED b396 |

---

## Fixed Items (b388-396)

### Phase 1 — Bugs
- [FIXED b388] B1: Nuclear fallback wrong filenames (removed writeRawData to wrong paths)
- [FIXED b388] B2: `reapplyCurrentEnforcement()` expired temp unlock (derive from ModeStackResolver)
- [FIXED already] B3: Monitor DNS blocklists cleared on unlock
- [FIXED b388] B4: `sendMessage` dedup key includes text hash
- [FIXED b388] B5: `markCommandProcessed` before receipt upload
- [FIXED b388] B6: `ModeStackResolver.resolve()` truly read-only
- [FIXED b388] B7: Schedule clear recomputes effective mode

### Phase 2 — Tunnel Parity (A1 partial)
- [FIXED b389] Temp unlock time anchor uses `issuedAt` (not `Date()`)
- [FIXED b389] Tunnel calls `storage.markCommandProcessed()`
- [FIXED b389] Main app checks `tunnelAppliedCommandIDs`
- [OPEN] Tunnel signature verification
- [OPEN] Tunnel lockUntil/timedUnlock full lifecycle

### Phase 3 — Enforcement Recovery
- [FIXED b388] R1: Temp unlock expiry retry extended to 30s (5 exponential attempts)
- [FIXED b388] R2: `temporaryUnlock` gets Monitor confirmation handshake
- [FIXED b388] R3: Tunnel fail-closed when shields confirmed down (any mode)
- [FIXED b388] R4: Force-close detection thresholds halved (10/20 min)
- [OPEN] R5: 15-minute reconciliation windows (needs activity budget tracker)
- [OPEN] R6: DeviceActivity 20-activity limit tracking
- [FIXED b394+396] R7: Background nuclear reset skipped, defers to Monitor. AppDelegate foreground-gated.
- [FIXED b388] R8: Rapid mode supersession preserves fallback
- [FIXED b391] R9: Monitor self-heals reconciliation registrations on every callback

### Phase 4 — Security
- [FIXED b388] S1: `uptimeAtStart` validated for clock manipulation
- [FIXED b388] S2: Default DeviceRestrictions (critical three = true)
- [REVERTED] S3: Command signing on empty Keychain (needs key re-enrollment first)
- [FIXED b393+396] S4: DNS blackhole deadlock — `.permissionsRevoked` clears when app opens, only activates when app dead
- [OPEN] S5: `allPermissionsGranted` flag child-writable (HMAC or Keychain)
- [FIXED b388] S6: Cross-process flock for commands and unlock requests
- [FIXED b388] A2: Unified permission-deficiency contract (`enforcementPermissionsOK`)

### Phase 5 — Tunnel Reliability (NEW, b396)
- [FIXED b396] RC1: `tunnelOwnsHeartbeat` cold-start bug
- [FIXED b396] RC2: CloudKit error logging + failure counter in command polling
- [FIXED b396] RC7: DNS proxy readLoop restart after settings reapply
- [FIXED b396] RC8: Command polling + unlock sync overlap guards
- [FIXED b396] RC5: Schedule `lockedMode == .unlocked` → `.restricted` safety net
- [FIXED b396] `clearTemporaryUnlock()` re-applies device restrictions
- [FIXED b396] `AppDelegate.restoreEnforcementIfNeeded()` foreground-gated + deterministic token sort

### Other
- [FIXED b392] Stale token detection + auto-refresh picker with app name display

---

## Still Open

| # | Item | Priority | Notes |
|---|------|----------|-------|
| A1 | Tunnel signature verification | High | Needs key re-enrollment on all devices first |
| R5 | 15-minute reconciliation windows | Medium | Needs R6 (activity budget) first |
| R6 | DeviceActivity 20-activity limit tracker | Medium | |
| S3 | Reject unsigned mode commands | Medium | Blocked on key re-enrollment |
| S5 | HMAC for permission flag | Low | |
| P1 | Shield diagnostics three-state model | Low | |
| P2 | Parent offline command queue | Low | |
| P3-P6 | DST edge case, version downgrade, JSON parsing | Low | |

## Requires Physical Access (Tonight)

1. **ALL kid devices**: Deploy b396 via USB
2. **Daphne + Olivia**: Settings > Screen Time > App & Website Activity OFF/ON
3. **Olivia**: Check for iCloud "Update Settings" banner
4. **Simon**: Re-save "High School" schedule from parent app (or b396 safety net fixes it)
5. **Future**: Send `addTrustedSigningKey` to all devices to restore command signing

## Previously Fixed (reference)

- [FIXED b331] DNS blackhole only for lockedDown
- [FIXED b338] `reconnectUpstream()` killing healthy DNS
- [FIXED b348] 8 blackhole flags → DNSBlockReason enum
- [FIXED b348] Schedule resolvedMode hardcoding
- [FIXED b348] ModeStackResolver priority
- [FIXED b360] Snapshot losing allowedAppTokensData
- [FIXED b360] Monitor temp unlock file reads
- [FIXED b361] Tunnel verifyEnforcementState killing DeviceActivity
- [FIXED b363] Tunnel stopping only current quarter
- [FIXED b385] 3 ManagedSettingsStore → 1 enforcement store

---

*Last updated: Apr 9 2026, build 396. 30+ items fixed across b388-396. 8 root causes identified via deep research.*
