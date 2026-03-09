# Xcode Project Setup — Big.Brother Phase 4

## Prerequisites

- Xcode 15.0+ (for iOS 17 SDK)
- Apple Developer account (paid membership)
- FamilyControls entitlement approved via App Store Connect (for full testing)
- Physical iOS 17+ device(s) for FamilyControls and extension testing
- CloudKit container created (see CLOUDKIT_SETUP.md)

## 1. Create the Xcode Project

1. **File > New > Project > App**
2. Product Name: `BigBrother`
3. Team: Your development team
4. Organization Identifier: `com.bigbrother`
5. Bundle Identifier: `com.bigbrother.app`
6. Interface: SwiftUI
7. Language: Swift
8. **Uncheck** "Include Tests" (we'll add test targets manually)
9. Save to the project root directory (alongside `BigBrotherCore/`, `BigBrotherApp/`, etc.)

**Important:** Remove the auto-generated `ContentView.swift` and `BigBrotherApp.swift` that Xcode creates — we have our own in `BigBrotherApp/App/`.

## 2. Add BigBrotherCore as Local Package

1. **File > Add Package Dependencies...**
2. Click **Add Local...** and select the `BigBrotherCore/` directory
3. Xcode will detect the package and show the `BigBrotherCore` library
4. Add the library to the main app target
5. Later, you'll also add it to each extension target

## 3. Configure Main App Target (BigBrother)

### Source Files

Remove any Xcode-generated source files, then add:
- All `.swift` files under `BigBrotherApp/App/` (AppState, BigBrotherApp, RootRouter, AppDelegate)
- All `.swift` files under `BigBrotherApp/Features/` (all views and view models)
- All `.swift` files under `BigBrotherApp/Services/` (all service implementations)

**Do NOT add extension source files** (`BigBrotherMonitor/`, `BigBrotherShield/`, `BigBrotherShieldAction/`) to the main app target.

### Entitlements

The entitlements file is pre-built at `BigBrotherApp/BigBrother.entitlements`.
- In Build Settings > Code Signing Entitlements, set the path to `BigBrotherApp/BigBrother.entitlements`
- Alternatively, add capabilities via Signing & Capabilities and Xcode will generate/update the file

### Capabilities (Signing & Capabilities tab)

Add these capabilities in order:
1. **App Groups** > Add `group.com.bigbrother.shared`
2. **iCloud** > Check CloudKit > Container: `iCloud.com.bigbrother.app`
3. **Keychain Sharing** > Add `com.bigbrother.shared`
4. **Family Controls** > Enable (requires Apple approval — see ENTITLEMENTS_SETUP.md)
5. **Push Notifications** > Enable
6. **Background Modes** > Check "Remote notifications"

### Frameworks

These frameworks are needed (most auto-link via `import` statements):
- `BigBrotherCore` (local package — added in step 2)
- `FamilyControls`
- `ManagedSettings`
- `DeviceActivity`
- `CloudKit`
- `LocalAuthentication`
- `UIKit` (implicit)
- `Combine` (for FamilyControlsManagerImpl)

### Info.plist

A pre-built `Info.plist` is at `BigBrotherApp/Info.plist`. It contains:
- `NSFaceIDUsageDescription`: "Big Brother uses Face ID to protect parent settings."
- `UIBackgroundModes`: `remote-notification`

Set the Info.plist path in Build Settings, or add these keys via the Xcode UI.

### Build Settings

| Setting | Value |
|---|---|
| PRODUCT_BUNDLE_IDENTIFIER | com.bigbrother.app |
| IPHONEOS_DEPLOYMENT_TARGET | 17.0 |
| SWIFT_VERSION | 5.9 |
| CODE_SIGN_ENTITLEMENTS | BigBrotherApp/BigBrother.entitlements |
| INFOPLIST_FILE | BigBrotherApp/Info.plist |

## 4. Create Extension Targets

### BigBrotherMonitor (DeviceActivityMonitor)

1. **File > New > Target**
2. Search for "Device Activity Monitor Extension"
3. Product Name: `BigBrotherMonitor`
4. Bundle Identifier: `com.bigbrother.app.monitor`
5. **Remove** the auto-generated source file
6. Add `BigBrotherMonitor/BigBrotherMonitorExtension.swift` to this target
7. Verify: the file's Target Membership shows only `BigBrotherMonitor`

**Capabilities:**
- App Groups > `group.com.bigbrother.shared`
- Keychain Sharing > `com.bigbrother.shared`
- Family Controls > Enable

**Frameworks:**
- BigBrotherCore (add via target's General > Frameworks)
- ManagedSettings
- DeviceActivity

**Entitlements:**
- Set CODE_SIGN_ENTITLEMENTS to `BigBrotherMonitor/BigBrotherMonitor.entitlements`

**Build Settings:**
| Setting | Value |
|---|---|
| PRODUCT_BUNDLE_IDENTIFIER | com.bigbrother.app.monitor |
| IPHONEOS_DEPLOYMENT_TARGET | 17.0 |

### BigBrotherShield (ShieldConfiguration)

1. **File > New > Target**
2. Search for "Shield Configuration Extension"
3. Product Name: `BigBrotherShield`
4. Bundle Identifier: `com.bigbrother.app.shield`
5. **Remove** the auto-generated source file
6. Add `BigBrotherShield/BigBrotherShieldExtension.swift` to this target

**Capabilities:**
- App Groups > `group.com.bigbrother.shared`
- Keychain Sharing > `com.bigbrother.shared`

**Frameworks:**
- BigBrotherCore
- ManagedSettings
- ManagedSettingsUI

**Entitlements:**
- Set CODE_SIGN_ENTITLEMENTS to `BigBrotherShield/BigBrotherShield.entitlements`

**Build Settings:**
| Setting | Value |
|---|---|
| PRODUCT_BUNDLE_IDENTIFIER | com.bigbrother.app.shield |
| IPHONEOS_DEPLOYMENT_TARGET | 17.0 |

### BigBrotherShieldAction (ShieldAction)

1. **File > New > Target**
2. Search for "Shield Action Extension"
3. Product Name: `BigBrotherShieldAction`
4. Bundle Identifier: `com.bigbrother.app.shield-action`
5. **Remove** the auto-generated source file
6. Add `BigBrotherShieldAction/BigBrotherShieldActionExtension.swift` to this target

**Capabilities:**
- App Groups > `group.com.bigbrother.shared`
- Keychain Sharing > `com.bigbrother.shared`

**Frameworks:**
- BigBrotherCore
- ManagedSettings

**Entitlements:**
- Set CODE_SIGN_ENTITLEMENTS to `BigBrotherShieldAction/BigBrotherShieldAction.entitlements`

**Build Settings:**
| Setting | Value |
|---|---|
| PRODUCT_BUNDLE_IDENTIFIER | com.bigbrother.app.shield-action |
| IPHONEOS_DEPLOYMENT_TARGET | 17.0 |

## 5. Verify Extension Embedding

After creating extension targets, verify in the main app target:
- General > Frameworks, Libraries, and Embedded Content
- All three extension `.appex` products should be listed as "Embed and Sign"

If they're not listed:
1. Go to the main app target > Build Phases > Embed App Extensions
2. Add all three extension products

## 6. Verify Signing

All four targets must use:
- **Same Development Team** (Team ID must match for Keychain sharing)
- **Same provisioning profile prefix** (for App Group access)
- Automatic signing is recommended for development

## 7. Build & Run

### First Build
1. Select the `BigBrother` scheme
2. Select a physical iOS 17+ device
3. Build (Cmd+B) — verify no errors
4. Run (Cmd+R)

### Build Order
Xcode should automatically build dependencies in order:
1. BigBrotherCore (Swift Package)
2. Extension targets (BigBrotherMonitor, BigBrotherShield, BigBrotherShieldAction)
3. BigBrother (main app, embeds extensions)

### Common First-Build Fixes
- If BigBrotherCore fails: verify Package.swift is valid (`swift build` in `BigBrotherCore/`)
- If extensions fail: verify framework linkage and target membership
- If signing fails: verify team and provisioning profiles

## 8. Test Targets

### BigBrotherCore Tests
Run via command line:
```bash
cd BigBrotherCore
swift test
```
154 tests across 18 suites should pass.

### App Target Tests (Future)
To create an app test target:
1. File > New > Target > Unit Testing Bundle
2. Product Name: `BigBrotherTests`
3. Target to be Tested: `BigBrother`
4. Add `@testable import BigBrother`
5. All services are protocol-based for easy mocking

## 9. Schemes

Create or verify these schemes:
- **BigBrother** — builds and runs the main app (includes extensions)
- **BigBrotherCore** — builds and tests the Swift Package only

For extension debugging:
1. Build and run the main app
2. Trigger the extension (schedule event, shield tap, etc.)
3. Xcode > Debug > Attach to Process > select the extension

## Related Documentation

- **ENTITLEMENTS_SETUP.md** — detailed entitlements and capabilities reference
- **CLOUDKIT_SETUP.md** — CloudKit container, schema, and subscription setup
- **DEVICE_TEST_PLAN.md** — physical device validation checklist
- **TROUBLESHOOTING.md** — common build and runtime issues with solutions
