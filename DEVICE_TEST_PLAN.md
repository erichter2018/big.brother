# Physical Device Validation Plan

## Prerequisites

- [ ] Two physical iOS 17+ devices (one parent, one child)
- [ ] Apple Developer account with valid provisioning profiles
- [ ] FamilyControls entitlement approved by Apple
- [ ] CloudKit container `iCloud.com.bigbrother.app` created with schema deployed
- [ ] Both devices signed in to iCloud accounts
- [ ] Xcode 15+ with project configured per XCODE_PROJECT_SETUP.md

---

## A. Initial Setup

### A1. Clean Install — Parent Device
- [ ] Delete any previous build from the device
- [ ] Build and install BigBrother app
- [ ] App launches to OnboardingView (role selection screen)
- [ ] No crash on launch
- [ ] No console errors about missing App Group or Keychain

### A2. Parent Setup
- [ ] Tap "Set Up as Parent"
- [ ] ParentSetupView appears
- [ ] Enter family name
- [ ] Tap "Create Family"
- [ ] FamilyID is generated and stored
- [ ] Device role set to `.parent`
- [ ] ParentPINSetupView appears
- [ ] Enter 4-8 digit PIN
- [ ] Confirm PIN
- [ ] PIN hash stored in Keychain (verify: no plaintext PIN in any storage)
- [ ] Redirected to ParentGate → ParentTabView
- [ ] Dashboard tab shows "No children configured yet"

### A3. CloudKit Verification — Parent
- [ ] Check CloudKit Dashboard: no errors in container
- [ ] Verify subscription was created (commands subscription for familyID)
- [ ] Settings tab shows CloudKit status: "Available" (or container identifier)

### A4. Add Child Profile
- [ ] Dashboard: tap "+" (person.badge.plus) in toolbar
- [ ] AddChildView: enter child name
- [ ] Tap "Create"
- [ ] Profile created in CloudKit (verify in Dashboard)
- [ ] Child appears in dashboard (with "No devices enrolled")

### A5. Generate Enrollment Code
- [ ] Tap child profile → ChildDetailView
- [ ] Tap "+" device button in toolbar → EnrollmentCodeView
- [ ] 8-character code is displayed
- [ ] Code is visible and copyable
- [ ] BBEnrollmentInvite record appears in CloudKit Dashboard

### A6. Child Device Enrollment
- [ ] Install BigBrother app on child device
- [ ] App launches to OnboardingView
- [ ] Tap "Enroll as Child Device"
- [ ] Enter enrollment code from parent device
- [ ] Code validates successfully
- [ ] EnrollmentPermissionsView: FamilyControls authorization prompt appears
- [ ] Approve authorization
- [ ] EnrollmentCompleteView: tap "Enroll This Device"
- [ ] Enrollment completes
- [ ] Device transitions to child mode (ChildHomeView)
- [ ] BBChildDevice record appears in CloudKit Dashboard
- [ ] BBEnrollmentInvite marked as used

### A7. Verify Parent Dashboard Updates
- [ ] Pull-to-refresh on parent dashboard
- [ ] Child profile now shows the enrolled device
- [ ] Device shows "Online" status (if heartbeat arrived)
- [ ] Device shows current mode badge

---

## B. Permissions & Entitlements

### B1. FamilyControls Authorization
- [ ] On child device: Settings > Screen Time shows Big Brother authorization
- [ ] In app: authorization health shows "authorized"
- [ ] Diagnostics: auth section shows "State: authorized"

### B2. App Group Access
- [ ] Child device: policy snapshot file exists in App Group container
- [ ] Extension shared state file exists in App Group container
- [ ] Shield config file exists in App Group container

### B3. Extension Availability
- [ ] DeviceActivityMonitor extension is listed in system processes (after schedule registration)
- [ ] ShieldConfiguration extension triggers when a shielded app is tapped
- [ ] ShieldAction extension responds to shield button taps

### B4. CloudKit Sign-In
- [ ] Parent device: CloudKit queries succeed
- [ ] Child device: CloudKit queries succeed
- [ ] Both devices: `CloudKitEnvironment.checkAccountStatus()` returns `.available`

---

## C. Core Flows

### C1. Send Command: Set Mode
- [ ] Parent: ChildDetailView → tap "Essential" button
- [ ] "Command sent" feedback appears
- [ ] BBRemoteCommand record created in CloudKit
- [ ] Child device receives silent push (may take 5-30 seconds)
- [ ] Child device processes command
- [ ] ManagedSettingsStore applies essential only restrictions
- [ ] BBCommandReceipt created in CloudKit
- [ ] Child ChildHomeView shows "Essential Only" mode
- [ ] Attempting to open a non-essential app shows shield screen

### C2. Send Command: Unlock
- [ ] Parent: tap "Unlock" button
- [ ] Child receives and processes
- [ ] ManagedSettingsStore clears all shields
- [ ] All apps accessible on child device

### C3. Send Command: Daily Mode
- [ ] Parent: tap "Daily" button
- [ ] Child device applies daily mode enforcement
- [ ] Non-allowed apps show shield screen
- [ ] (If always-allowed apps are configured) Allowed apps remain accessible

### C4. Heartbeat Upload
- [ ] Wait 5 minutes on child device
- [ ] Heartbeat auto-sends (check BBHeartbeat in CloudKit Dashboard)
- [ ] Parent dashboard: pull-to-refresh shows updated "Last seen" time
- [ ] Battery level and charging status reported correctly

### C5. Event Log Upload
- [ ] Trigger mode change on child device
- [ ] Event logged locally (check Diagnostics)
- [ ] After sync cycle: BBEventLog record appears in CloudKit Dashboard
- [ ] Parent: child detail shows event in "Recent Events (24h)"

### C6. Local Parent Unlock
- [ ] Child device: tap "Parent Unlock" at bottom of ChildHomeView
- [ ] LocalUnlockView appears
- [ ] Enter parent PIN
- [ ] Temporary unlock activates (30 min default)
- [ ] ChildHomeView shows "Temporary Unlock" card with countdown
- [ ] All apps accessible during unlock period
- [ ] Event logged: "localPINUnlock"

### C7. Temporary Unlock Expiry
- [ ] Wait for temporary unlock to expire (or set shorter duration for testing)
- [ ] On expiry: enforcement reverts to previous mode
- [ ] TemporaryUnlockCard disappears
- [ ] Event logged: "temporaryUnlockExpired"
- [ ] Previous mode's shields re-applied

### C8. Schedule Start/End
- [ ] Parent: create a schedule for the child (e.g., "Test Schedule", 1 minute from now)
- [ ] Schedule saved to CloudKit
- [ ] Child device: schedule registered with DeviceActivityCenter
- [ ] When schedule starts: DeviceActivityMonitor extension fires
- [ ] Extension applies schedule-mode enforcement
- [ ] When schedule ends: extension clears schedule store
- [ ] Base policy enforcement remains active

### C9. App Relaunch Restore
- [ ] Child device: set mode to "Essential Only"
- [ ] Force-quit the BigBrother app
- [ ] Relaunch the app
- [ ] AppLaunchRestorer runs
- [ ] Enforcement state matches pre-quit mode (Essential Only still active)
- [ ] Diagnostics: "Launch reconciliation" entry appears

### C10. Device Reboot Restore
- [ ] Child device: set mode to "Essential Only"
- [ ] Reboot the device
- [ ] ManagedSettingsStore persists across reboot (no app launch needed)
- [ ] Shielded apps still show shield screen before app launches
- [ ] When app launches: restoration verifies enforcement is correct

---

## D. Failure & Degraded Cases

### D1. Revoke FamilyControls Authorization
- [ ] Child device: Settings > Screen Time > remove Big Brother authorization
- [ ] App detects change via `AuthorizationCenter.$authorizationStatus` observation
- [ ] AuthorizationHealth transitions to "denied"
- [ ] ChildHomeView shows authorization warning card
- [ ] Event logged: "familyControlsAuthChanged"
- [ ] Diagnostics shows: "enforcementDegraded: Yes"
- [ ] ManagedSettingsStore shields are cleared by the system

### D2. Restore FamilyControls Authorization
- [ ] Re-enable authorization in Settings > Screen Time
- [ ] App detects restoration
- [ ] Event logged: "authorizationRestored"
- [ ] Enforcement re-applied from current snapshot
- [ ] Warning card disappears

### D3. CloudKit Unavailable
- [ ] Enable Airplane Mode on child device
- [ ] Heartbeat send fails silently (retry with backoff)
- [ ] Local enforcement continues (snapshot-based)
- [ ] Event queue accumulates locally
- [ ] Disable Airplane Mode
- [ ] Next sync cycle uploads pending events and heartbeat
- [ ] Commands sent while offline are received on reconnect

### D4. CloudKit Account Signed Out
- [ ] Sign out of iCloud on the device
- [ ] `CloudKitEnvironment.checkAccountStatus()` returns `.noAccount`
- [ ] App shows status message about iCloud unavailability
- [ ] Local enforcement continues unaffected
- [ ] Sign back in → sync resumes

### D5. Stale Heartbeat
- [ ] Disable networking on child device for > 10 minutes
- [ ] Parent dashboard: device shows "Offline"
- [ ] HeartbeatStatus: `consecutiveFailures` increments
- [ ] Backoff interval increases

### D6. Extension Unable to Decode Shared State
- [ ] (Simulate by corrupting extension_shared_state.json in App Group — developer testing only)
- [ ] Extension falls back to reading full policy_snapshot.json
- [ ] If both corrupted: extension does nothing (safe default)
- [ ] App's next sync cycle rewrites the shared state files

### D7. Parent PIN Lockout
- [ ] Enter wrong PIN 5 times on child device (local unlock)
- [ ] Lockout activates (5 minute cooldown)
- [ ] Lockout message displayed with countdown
- [ ] After lockout expires: PIN entry allowed again
- [ ] Correct PIN succeeds

### D8. Parent PIN Lockout on Parent Gate
- [ ] On parent device: enter wrong PIN repeatedly
- [ ] Same lockout behavior as child local unlock
- [ ] After lockout: correct PIN grants access

---

## E. Always Allowed App Token Flow

### E1. Select Apps
- [ ] Parent: child detail → navigate to AlwaysAllowedSelectionView
- [ ] FamilyActivityPicker appears
- [ ] Select several apps (e.g., Calculator, Notes)
- [ ] Tap "Save Selection"
- [ ] "Saved" feedback appears
- [ ] CloudKit: BBChildProfile updated with alwaysAllowedCategoriesJSON data

### E2. Verify Enforcement
- [ ] Set child to "Daily Mode"
- [ ] Child device: selected apps are NOT shielded (accessible)
- [ ] Non-selected apps ARE shielded
- [ ] Verify shield screen appears for non-allowed apps

### E3. Persist Across Relaunch
- [ ] Force-quit child app
- [ ] Relaunch
- [ ] Selected apps still accessible in Daily Mode
- [ ] Shield still active for non-selected apps

### E4. Modify Selection
- [ ] Parent: change always-allowed selection (add/remove apps)
- [ ] Save
- [ ] Send "Daily Mode" command to force policy refresh
- [ ] Child: new selection reflected in enforcement

### E5. Token Serialization Validation
- [ ] Check Diagnostics on child device: policy snapshot contains `allowedAppTokensData`
- [ ] Token data size is reasonable (< 50KB)
- [ ] Tokens survive Codable round-trip (no deserialization errors in logs)

---

## F. Multi-Device Scenarios

### F1. Multiple Children
- [ ] Add second child profile on parent device
- [ ] Enroll second device for second child
- [ ] Set different modes for each child
- [ ] Each child device enforces its own mode independently
- [ ] Parent dashboard shows both children with correct status

### F2. Global Actions
- [ ] Parent dashboard: tap "Lock All"
- [ ] All child devices receive command
- [ ] All devices enter Locked mode
- [ ] Parent dashboard: tap "Unlock All"
- [ ] All devices unlock

### F3. Device-Specific Commands
- [ ] Parent: DeviceDetailView → set mode for specific device
- [ ] Only that device changes mode
- [ ] Other devices for the same child are unaffected

---

## G. Performance & Stability

### G1. Memory Usage
- [ ] Run child app for extended period (1+ hour)
- [ ] No memory leaks (check Xcode memory graph)
- [ ] Extension memory usage stays within system limits

### G2. Battery Impact
- [ ] Monitor battery usage in Settings > Battery
- [ ] BigBrother should not appear in top battery consumers
- [ ] Heartbeat interval (5 min) is reasonable for battery life

### G3. Extension Reliability
- [ ] Leave child device running overnight with schedule active
- [ ] Schedule start/end events fire correctly
- [ ] Reconciliation schedule runs hourly
- [ ] Enforcement remains consistent

---

## Test Results Template

| Test | Pass | Fail | Notes |
|---|---|---|---|
| A1 Clean Install | [ ] | [ ] | |
| A2 Parent Setup | [ ] | [ ] | |
| A3 CloudKit Verify | [ ] | [ ] | |
| ... | | | |

Date tested: ___________
iOS version: ___________
Devices used: ___________
Tester: ___________
