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
| F1 | NSLog → OSLog modernization across tunnel + services | Low | Mostly mechanical; deferred |

## Session — b653 (2026-04-17): Juliet freeze fix + broad main-thread hardening

Root cause identified via StartupWatchdog signal-based backtrace: main was stuck in synchronous `deviceactivityd` XPC from `ScheduleRegistrar.registerTimeLimitEvents`, called from `AppState.applyTimeLimitConfigLocally` (@MainActor). Fix pattern + audit propagated across the codebase.

- [FIXED b650 on juliet/b653 on main] `ScheduleRegistrar.registerTimeLimitEvents` dispatched off-main at both AppState call sites.
- [FIXED b653] `CommandProcessorImpl.triggerMonitorEnforcementRefresh` + `cancelNonScheduleActivities` wrapped in `DispatchQueue.global.async` — used to run synchronously from `applyMode` which is called on MainActor via `applyModeDirect`.
- [FIXED b653] `scheduleEnforcementRefreshActivity` (EnforcementServiceImpl) body moved to `DispatchQueue.global.async` (was called from `applyMode` on main).
- [FIXED b653] `AppState.applyTimedUnlockStart`, `applyTimedUnlockEnd`, `enforcePenaltyPhaseLock`, `enforceScheduleTransition` all wrap `applyModeDirect` in `Task.detached` so the synchronous ManagedSettings/DeviceActivity XPC can't freeze main.
- [FIXED b653] `withDeadline(seconds:)` helper in TaskTimeout.swift. Wraps every `.refreshable { ... }` site in the parent app with a 30-second deadline. Uses unstructured `Task.detached` + continuation one-shot — structured task groups can't be used because their scope exit awaits children, which would re-block on the wedged XPC.
- [FIXED b653] `ChildDetailViewModel.refresh()` uses `withDeadline(30)` — pull-to-refresh on the kid view now releases even when CloudKit hangs.
- [FIXED b653] `ActivityFeedViewModel.computeWeeklySummary` falls back to heartbeat/DNS-only when `fetchEventLogs` throws. Prevents "No Data" when one CK call fails.
- [FIXED b653] `fetchWeekDNSSnapshot` parallelized via `withTaskGroup` (was serial N×7 CK reads, 30-60s on slow cloudd → parallel single-fetch latency).
- [FIXED b653] Rejected-app re-submit unblocked in `ChildHomeViewModel` + `ChildAppPickView` (removed early-return on inactive config). Parent-side `review(_, isSupersededBy:)` filter already handles fresh reviews correctly.
- [FIXED b653] Tunnel DNS deception Phase 1 threshold raised to dominant-app (≥3 hits AND >50%) so a single `facebook.com` from a Google Earth share-SDK no longer mislabels the app.
- [FIXED b653] StartupWatchdog + SIGUSR1-based main-thread backtrace capture + pull_launch_log.sh retained in main. Standing infra for diagnosing future UI freezes on any device.
- [FIXED b653 — codex audit finding] `withDeadline` / `ChildDetailViewModel.refresh` replaced the task-group deadline (which re-blocked at scope exit) with a continuation-based one-shot that returns when either the worker or the sleep finishes, without awaiting the worker at scope exit.
- [FIXED b653 — gemini audit finding] `applyTimedUnlockEnd` retry branch no longer skips the final `refreshLocalState` + `ModeChangeNotifier.notify` — previously the UI stayed stale until the 10s enforcement-verify timer kicked in.
- [IN PROGRESS b653] `forKey:` literal migration across all non-tunnel targets (AppGroupKeys typed constants) — subagent handled ~30 files. Compile-check gates each.
- [OPEN] Stale-generation race in `ScheduleRegistrar.registerTimeLimitEvents` dispatch (codex): two rapid updates can race if both snapshots dispatched to `DispatchQueue.global` finish out of order. Fix: serialize through one dedicated queue and re-read the latest snapshot inside.
- [OPEN] Thrash in `enforceScheduleTransition`: 1s timer can queue repeated `applyModeDirect` calls until `refreshLocalState()` catches up. Fix: in-flight flag guard.

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
