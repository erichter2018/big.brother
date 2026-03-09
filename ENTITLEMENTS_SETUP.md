# Entitlements & Capabilities Setup

## Capability Matrix

| Capability | BigBrother (App) | Monitor (Ext) | Shield (Ext) | ShieldAction (Ext) |
|---|---|---|---|---|
| App Groups | YES | YES | YES | YES |
| Keychain Sharing | YES | YES | YES | YES |
| iCloud / CloudKit | YES | - | - | - |
| Push Notifications | YES | - | - | - |
| Background Modes | YES (remote-notification) | - | - | - |
| Family Controls | YES | YES | - | - |

## App Group

**Identifier:** `group.com.bigbrother.shared`

All four targets share this App Group. It provides:
- A shared file-system container for JSON files (policy snapshot, shield config, event queue, etc.)
- Shared UserDefaults (not currently used; all shared data is in JSON files)

The App Group must be registered in the Apple Developer portal and added to all four targets' capabilities.

## Keychain Sharing

**Access Group:** `$(AppIdentifierPrefix)com.bigbrother.shared`

The Keychain access group allows the main app and all extensions to share:
- Device role (parent/child/unconfigured)
- Enrollment state (child devices)
- Parent state (parent devices)
- Parent PIN hash (PBKDF2-HMAC-SHA256)
- Family ID

**Important:** The `$(AppIdentifierPrefix)` prefix is automatically expanded by Xcode to your Team ID. All targets must use the same team.

## iCloud / CloudKit

**Container:** `iCloud.com.bigbrother.app`
**Database:** Public (no private database needed)

Only the main app target needs the CloudKit entitlement. Extensions cannot make network calls — they read shared state from the App Group container.

The CloudKit container must be created in the CloudKit Dashboard before first use.

## Push Notifications

**Type:** Silent push (content-available)

CloudKit CKQuerySubscription delivers silent pushes when new records match the subscription predicate. The app receives these via `UIApplicationDelegate.didReceiveRemoteNotification`.

The `aps-environment` entitlement key is set to `development` in the entitlements file. Change to `production` for App Store builds.

## Family Controls

**Entitlement:** `com.apple.developer.family-controls`

This entitlement requires Apple approval via App Store Connect. Without approval:
- The app will build and run
- `AuthorizationCenter.shared.requestAuthorization(for: .individual)` will fail
- All enforcement features will be non-functional
- The app will report `enforcementDegraded` state

**How to request:**
1. Go to App Store Connect > your app
2. Features > Family Controls
3. Submit the approval request with justification
4. Wait for Apple review (typically 1-2 weeks)

**Which targets need it:**
- BigBrother (main app) — to request authorization and apply ManagedSettings
- BigBrotherMonitor — to apply shield settings via ManagedSettingsStore in the extension
- BigBrotherShield and BigBrotherShieldAction do NOT need the Family Controls entitlement — they use ManagedSettings/ManagedSettingsUI which don't require it

## Background Modes

**Mode:** `remote-notification`

Enables the app to be woken by silent push notifications from CloudKit subscriptions. When a new command is created in CloudKit, the CKQuerySubscription fires a silent push, which wakes the app and triggers `BackgroundRefreshHandler.handleRemoteNotification`.

## Entitlement Files

Pre-built entitlement files are provided in each target directory:

| Target | File |
|---|---|
| BigBrother | `BigBrotherApp/BigBrother.entitlements` |
| BigBrotherMonitor | `BigBrotherMonitor/BigBrotherMonitor.entitlements` |
| BigBrotherShield | `BigBrotherShield/BigBrotherShield.entitlements` |
| BigBrotherShieldAction | `BigBrotherShieldAction/BigBrotherShieldAction.entitlements` |

## Xcode Configuration

In each target's Build Settings:
- Set `CODE_SIGN_ENTITLEMENTS` to the appropriate `.entitlements` file path
- Ensure all targets use the same Development Team
- Ensure all targets use the same App Group identifier

## What Cannot Be Validated Without Apple Approval

1. **FamilyControls authorization** — requires Apple-approved entitlement
2. **ManagedSettingsStore shielding** — works only with approved FamilyControls
3. **DeviceActivity schedule callbacks** — works only with approved FamilyControls
4. **Shield/ShieldAction UI** — system only invokes these when shielding is active

Everything else (CloudKit, App Group, Keychain, push notifications, background modes) can be tested with a standard Apple Developer account.
