# Phase 3.5+ — Cleanup & Polish Notes

Items for a future polish pass after device testing and initial deployment.
Phase 3.5 cleanup pass is complete. Phase 4 deployment readiness is complete.

## UI Polish
- [ ] Add haptic feedback on mode changes and PIN entry
- [ ] Animate mode transitions in ChildHomeView (icon + color morph)
- [ ] Add pull-to-refresh indicator on ChildHomeView (currently parent-only)
- [ ] SwiftUI animation for TemporaryUnlockCard countdown
- [ ] Accessibility labels for all custom components (ModeBadge, StatusBadge, etc.)
- [ ] VoiceOver testing pass on all screens
- [ ] Dark mode visual audit (ensure all custom colors adapt correctly)
- [ ] iPad layout optimization (sidebars, split views for parent dashboard)

## Error Handling
- [ ] Retry logic for CloudKit operations in view models (currently single attempt + error display)
- [ ] Offline mode indication in parent dashboard header
- [ ] Network reachability check before CloudKit operations
- [ ] Better error messages (translate CKError codes to user-friendly strings)

## Security
- [ ] PIN brute-force rate limiting at CloudKit level (in addition to local lockout)
- [ ] Biometric re-prompt after app backgrounding for > 5 minutes (already partially implemented in ParentGate)
- [ ] Audit log for PIN changes (currently only logged locally)
- [ ] Consider adding a "wipe PIN" flow requiring Apple ID re-auth

## Performance
- [ ] CloudKit query result caching with TTL for parent dashboard
- [ ] Lazy loading for event log history (currently loads all at once)
- [ ] Background refresh for parent dashboard (BGAppRefreshTask)
- [ ] Profile image/avatar caching

## Schedule System
- [ ] Conflict detection: warn when two schedules overlap for the same child
- [ ] Schedule preview: show "what mode will be active" timeline for next 24h
- [ ] Quick-toggle schedule activation from list view (without opening editor)
- [ ] Copy schedule to another child

## Extension Improvements
- [ ] ShieldConfiguration: customizable per-child messaging ("Simon, this app is restricted during school hours")
- [ ] ShieldAction: "Request Unlock" button that creates a CloudKit notification to parent
- [ ] DeviceActivityMonitor: smarter reconciliation — compare against both snapshot and ManagedSettingsStore state

## Testing
- [ ] XCUITest suite for critical flows (onboarding, PIN entry, mode changes)
- [ ] CloudKit integration tests with mock container
- [ ] Snapshot tests for UI components
- [ ] App-target unit tests for view models (requires Xcode test target)

## Architecture
- [ ] Consider extracting view models to a ViewModels module (testable without app target)
- [ ] CloudKit error type unification (currently scattered across service boundaries)
- [ ] Structured concurrency audit (ensure all Task blocks handle cancellation)
- [ ] Memory leak audit (weak self in closures, timer cleanup)

## Misc
- [ ] App icon and launch screen
- [ ] Onboarding illustrations
- [ ] "About" screen with licenses
- [ ] Telemetry/analytics opt-in for crash reporting
- [ ] Widget extension for parent: quick-glance child status
- [ ] Notification support: alert parent when child's auth is revoked, device goes offline, etc.
