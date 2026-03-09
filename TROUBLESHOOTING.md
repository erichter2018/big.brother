# Troubleshooting Guide

## Build Issues

### "No such module 'BigBrotherCore'"
**Cause:** Local Swift Package not linked to the target.
**Fix:**
1. File > Add Package Dependencies > Add Local > select `BigBrotherCore/`
2. Ensure the `BigBrotherCore` library is added to the failing target under General > Frameworks
3. Clean build folder (Cmd+Shift+K) and rebuild

### "No such module 'FamilyControls'" or 'ManagedSettings'
**Cause:** Building for Simulator, which doesn't support FamilyControls well, or SDK mismatch.
**Fix:**
1. Build for a physical device target, not Simulator
2. Ensure deployment target is iOS 17.0+
3. Verify Xcode 15+ is installed

### "Provisioning profile doesn't include the Family Controls entitlement"
**Cause:** Apple hasn't approved the FamilyControls entitlement for your app.
**Fix:**
1. Submit the entitlement request via App Store Connect > Features > Family Controls
2. Wait for approval (1-2 weeks typically)
3. Until approved: remove the Family Controls capability to build without enforcement

### Extension targets fail to build
**Cause:** Missing framework linkage or wrong target membership.
**Fix:**
- BigBrotherMonitor: link `BigBrotherCore`, `ManagedSettings`, `DeviceActivity`
- BigBrotherShield: link `BigBrotherCore`, `ManagedSettings`, `ManagedSettingsUI`
- BigBrotherShieldAction: link `BigBrotherCore`, `ManagedSettings`
- All extensions: verify source files belong to correct target (not the main app target)

---

## Runtime Issues

### App crashes on launch: "App Group container not available"
**Cause:** App Group capability not configured or identifier mismatch.
**Fix:**
1. Signing & Capabilities > verify App Groups includes `group.com.bigbrother.shared`
2. Verify the identifier matches `AppConstants.appGroupIdentifier`
3. Verify the App Group is registered in the Apple Developer portal
4. Verify the provisioning profile includes the App Group

### "Failed to request FamilyControls authorization"
**Cause:** Entitlement not approved, or running on Simulator.
**Fix:**
1. Must use a physical device
2. Must have Apple-approved FamilyControls entitlement
3. Check that the entitlements file includes `com.apple.developer.family-controls`
4. The user must tap "Allow" on the system authorization prompt

### Parent PIN verification fails after reinstall
**Cause:** Keychain data persists across app installs, but App Group data doesn't.
**Fix:** This is expected behavior. The PIN hash is in Keychain (which persists), but if the app was uninstalled and reinstalled, the role might need to be re-established. If the user's role is `.unconfigured` but PIN exists in Keychain, they can set up as parent again.

### CloudKit queries return empty results
**Cause:** Schema not deployed, indexes missing, or wrong container.
**Fix:**
1. CloudKit Dashboard: verify the container identifier matches `iCloud.com.bigbrother.app`
2. Verify all record types are created with correct field names
3. Verify queryable indexes are set on `familyID` for all record types
4. Verify the device is signed in to iCloud
5. Check "Development" vs "Production" environment — development data is separate
6. Try "Reset Development Environment" in CloudKit Dashboard if records are corrupted

### Child device doesn't receive commands
**Cause:** Push notifications not registered, or CloudKit subscription missing.
**Fix:**
1. Verify `UIApplication.shared.registerForRemoteNotifications()` was called (AppDelegate does this)
2. Check CloudKit Dashboard > Subscriptions for the family's subscription
3. Verify the child device is signed in to iCloud
4. Verify the device has network connectivity
5. Silent pushes may be delayed by the system (especially in low-power mode)
6. Fallback: the heartbeat sync cycle (every 5 minutes) also fetches commands

### ManagedSettingsStore doesn't apply shields
**Cause:** FamilyControls authorization revoked or not approved.
**Fix:**
1. Check `AuthorizationCenter.shared.authorizationStatus` — must be `.approved`
2. If `.denied`: user revoked in Settings > Screen Time, or entitlement not approved
3. If `.notDetermined`: authorization was never requested, or request failed silently
4. Check Diagnostics > Authorization Health for the current state

### Shield screen shows but no custom UI
**Cause:** ShieldConfiguration extension not running.
**Fix:**
1. Verify the extension target is embedded in the app
2. Verify the extension source file belongs to the correct target
3. Debug: Xcode > Debug > Attach to Process > "BigBrotherShield"
4. Extension may not be called until a shielded app is actually tapped

### Heartbeat not sending
**Cause:** Timer not started, CloudKit unavailable, or enrollment state missing.
**Fix:**
1. Verify the device role is `.child` and enrollment state exists
2. Check `HeartbeatServiceImpl` timer is started (`startHeartbeat()` called)
3. Check CloudKit account status
4. Check Diagnostics > Heartbeat Status for failure details and backoff state
5. Airplane mode or poor connectivity will cause silent failures with backoff

---

## Debugging Tools

### Xcode Console Filtering
Filter console output by:
- `[BigBrother]` — app-level debug prints
- `com.bigbrother` — Keychain and App Group operations
- `ManagedSettings` — framework shield operations
- `DeviceActivity` — schedule monitoring

### CloudKit Dashboard
- **Records:** View, create, edit, and delete records in any record type
- **Subscriptions:** View active subscriptions per database
- **Logs:** Check for operation errors in the Logs tab
- **Telemetry:** Monitor request rates and error rates
- **Schema:** Verify record types, fields, and indexes

### Diagnostics View
The app's built-in Diagnostics screen (Settings > Diagnostics) shows:
- Current policy snapshot (ID, generation, mode, source, fingerprint)
- Authorization health (state, transitions, degraded flag)
- Heartbeat status (last success, failures, backoff)
- Extension shared state (mode, temp unlock, policy version)
- Snapshot history (all transitions with diffs)
- Diagnostic log (filtered by category)

### App Group File Inspection
On a development device, you can inspect App Group files:
1. Xcode > Window > Devices and Simulators
2. Select the device > BigBrother app
3. Download Container
4. Browse `AppGroup/group.com.bigbrother.shared/`
5. JSON files: `policy_snapshot.json`, `extension_shared_state.json`, etc.

### Extension Debugging
1. Build and run the main app
2. Trigger the extension (tap a shielded app, or wait for schedule)
3. Xcode > Debug > Attach to Process by PID or Name
4. Select the extension process (e.g., `BigBrotherMonitor`)
5. Set breakpoints in extension code

---

## Common Failure Modes

### Enforcement Lost After Reboot
**Expected:** ManagedSettingsStore persists across reboot. Shields stay active.
**If not working:** The FamilyControls entitlement may be revoked, or the extension crashed.
**Verify:** Launch the app → AppLaunchRestorer runs → reconciles enforcement.

### Time-Based Schedule Not Firing
**Possible causes:**
1. Schedule not registered with DeviceActivityCenter
2. Schedule times in the past
3. Device in low-power mode (system may delay extension wake)
4. DeviceActivity framework bug (known to occasionally miss intervals)
**Workaround:** The reconciliation schedule fires hourly to catch missed events.

### Token Data Corruption
**Symptoms:** FamilyActivitySelection fails to decode from stored data.
**Cause:** iOS version change may alter token serialization format.
**Fix:** Have the parent re-select allowed apps. Tokens are device-specific opaque types.

### Enrollment Code Expired
**Symptoms:** Child device rejects enrollment code.
**Cause:** Code expires after 30 minutes (`AppConstants.enrollmentCodeValiditySeconds`).
**Fix:** Generate a new code from the parent device.

### "Policy v0" or Missing Policy
**Cause:** Child device hasn't synced with CloudKit yet, or parent hasn't set a policy.
**Fix:**
1. Ensure CloudKit is available on both devices
2. Parent: send a mode command to the child
3. Child: pull-to-refresh or wait for next sync cycle

---

## Environment-Specific Notes

### Development vs Production CloudKit
- Development and Production are separate environments with separate data
- Use "Deploy Schema to Production" in CloudKit Dashboard before App Store submission
- Development environment can be reset without affecting production

### TestFlight
- TestFlight builds use the Production CloudKit environment
- Ensure schema is deployed to Production before TestFlight testing
- Push notifications work on TestFlight (uses production APN environment)

### App Store Review
- FamilyControls apps require additional review by Apple
- Include a demo account or test instructions in App Store Connect
- Explain the parental control use case in the review notes
- Apple may request a video demonstrating the app's functionality
