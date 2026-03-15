# Token-to-App-Name Resolution: Approaches & Failures

This document chronicles every approach attempted to map opaque `ApplicationToken` / `ActivityCategoryToken` values from Apple's Screen Time frameworks (FamilyControls, ManagedSettings, DeviceActivity) to human-readable app names — what worked, what failed, and why.

## Background

Apple's Screen Time API uses opaque token types (`ApplicationToken`, `ActivityCategoryToken`, `WebDomainToken`) that intentionally hide the underlying app identity from third-party code. These tokens can be used to block or allow apps via `ManagedSettingsStore`, but extracting a human-readable name from them is deliberately restricted.

This is a fundamental design tension: we need to show parents *which* apps their children are using or requesting access to, but Apple actively prevents programmatic extraction of this information outside of specific privileged extension contexts.

---

## Part 1: Direct Token Inspection (All Failed)

### 1.1 — `Application(token:).localizedDisplayName`

**Approach:** Wrap the token in an `Application` struct and read its `localizedDisplayName` property.

**Result:** Returns `nil` on device. The property exists in the API but is not populated when accessed from the main app process.

**Confirmed:** 2026-03-13, on-device testing.

### 1.2 — `Application(token:).bundleIdentifier`

**Approach:** Same wrapper, reading `bundleIdentifier` instead.

**Result:** Returns `nil`. Same restriction as `localizedDisplayName`.

### 1.3 — `String(describing: token)`

**Approach:** Use Swift's string interpolation/description to extract any useful info from the token.

**Result:** Returns `"ApplicationToken(data: 128 bytes)"`. The token is an opaque 128-byte blob with no embedded metadata accessible this way.

### 1.4 — Accessibility Label Extraction from `Label(ApplicationToken)`

**Approach:** SwiftUI's `Label` initializer accepts an `ApplicationToken` and renders the app name + icon. We attempted to read the accessibility properties (`.accessibilityLabel`, `.accessibilityValue`, `.accessibilityHint`) from a programmatically created `Label(token)`.

**Result:** All accessibility properties return `nil`. Deep subview walk through the entire view hierarchy found no accessibility information in any subview.

---

## Part 2: Rendering & Screen Capture (All Failed)

### 2.1 — `Label(token)` in offscreen `UIHostingController` + `drawHierarchy`

**Approach:** Create a `UIHostingController` hosting a `Label(token)`, lay it out offscreen, then use `drawHierarchy(in:afterScreenUpdates:)` to capture the rendered text as an image (for OCR or visual reading).

**Result:** Renders a solid black rectangle. `drawHierarchy` cannot capture offscreen views.

### 2.2 — `Label(token)` in window-attached `UIHostingController` + `layer.render`

**Approach:** Attach the hosting controller's view to the actual window hierarchy, then use `layer.render(in:)` to capture it.

**Result:** Renders a solid white rectangle. The view reports `intrinsicContentSize` of 300x112 (suggesting the Label *does* know its layout), but the rendered output contains zero visible content. The system blocks rendering of Screen Time UI elements outside their intended context.

### 2.3 — `ImageRenderer` / `UIHostingController` in Extension

**Approach:** Use SwiftUI's `ImageRenderer` or a `UIHostingController` inside the DeviceActivityReport extension to render `Label(ApplicationToken)` to an image.

**Result:** Platform representable requires LaunchServices access. Cannot render token labels to images even within the extension.

---

## Part 3: Extension-to-App Data Channels (All Failed)

The DeviceActivityReport extension *can* resolve token names internally (see Part 5). The challenge is getting that data back to the main app. Every outbound channel is blocked.

### 3.1 — File Write (Atomic) from Extension

**Approach:** Write a JSON cache file to the App Group container using atomic write (`Data.write(to:options:.atomic)`).

**Result:** `"Operation not permitted"`. The extension sandbox blocks file writes to App Group.

### 3.2 — File Write (FileHandle) from Extension

**Approach:** Use `FileHandle(forWritingTo:)` for non-atomic writes.

**Result:** `"You don't have permission"`. Same sandbox restriction, different error message.

### 3.3 — File Write from `.task(id:)` in View Body

**Approach:** Instead of writing from `makeConfiguration()`, write from a `.task(id:)` modifier attached to the extension's SwiftUI view, hoping the view rendering context has different permissions.

**Result:** Same "Operation not permitted" errors. The sandbox applies uniformly to all code running in the extension process, regardless of which method initiates the write.

**Confirmed:** 2026-03-13.

### 3.4 — `UserDefaults(suiteName:)` from `makeConfiguration()`

**Approach:** Write resolved names to shared `UserDefaults` using the App Group suite name.

**Result:** Blocked. `cfprefsd` sandbox denial prevents the extension from writing to shared defaults.

### 3.5 — `UserDefaults(suiteName:)` from `.task(id:)` in View Body

**Approach:** Same as 3.4 but from the view context.

**Result:** Same sandbox denial. The execution context doesn't matter.

**Confirmed:** 2026-03-13.

### 3.6 — Keychain (`SecItemAdd`) from Extension

**Approach:** Write resolved names to the shared Keychain group, hoping `securityd` would bypass the file sandbox.

**Result:** Blocked. `"System Keychain Always Supported"` flag is disabled for DeviceActivityReport extensions. `SecItemAdd` returns an error.

**Note:** This is particularly frustrating because ShieldAction extensions *can* write to Keychain and App Group. The DeviceActivityReport extension is uniquely locked down.

### 3.7 — `openURL` from Extension SwiftUI View

**Approach:** Use SwiftUI's `openURL` environment action from the extension's view to send a custom URL scheme (`bigbrother://names?data=...`) back to the main app.

**Result:** The URL open call completes without error, but the main app's `onOpenURL` handler never fires. No receipt. The URL goes nowhere.

**Confirmed:** 2026-03-13.

### 3.8 — QR Code Visual Bridge

**Approach:** Generate QR codes inside the DeviceActivityReport extension view containing encoded name data (using PureSwiftQR, a pure-Swift QR generator with no UIKit dependencies). Then capture the rendered QR code from the main app using `drawHierarchy` on the embedded `DeviceActivityReport` view.

**Result:** PureSwiftQR successfully generates valid QR codes inside the extension. However, `drawHierarchy` captures the **privacy overlay** instead — a solid green rectangle (RGB 0/60/0). iOS replaces the extension's actual rendered content with this privacy shield when captured programmatically.

This was the most creative approach and the closest to working. Blocked at the last mile by iOS screenshot protection of extension views.

### Apple Confirmation

**Apple DTS confirmed (forum thread #728044):** DeviceActivityReport intentionally prevents ALL outbound data channels to "prevent information leaking." This is by design, not a bug. The extension is meant to be display-only.

---

## Part 4: App Blocking Discoveries (Informed the Problem)

### 4.1 — `shield.applications` Does Not Block Apps

**Approach:** Set `ManagedSettingsStore.shield.applications` with specific `ApplicationToken` values to block individual apps.

**Result:** Apps remain completely unblocked. Tested with 3, 7, and 159 tokens from `FamilyActivityPicker`. Per-app blocking via `shield.applications` is non-functional.

### 4.2 — `shield.applicationCategories = .all()` Does Block

**Result:** Reliably blocks all apps. This is the only working blocking method.

### 4.3 — `.all(except: Set<ApplicationToken>)` Does Unblock

**Result:** Reliably allows specific apps through the category block. Confirmed working for per-app unlocks.

### 4.4 — Setting Both `shield.applications` AND `shield.applicationCategories`

**Result:** Everything routes through the category handler. The per-app `ShieldAction` handler never fires. The per-app `ShieldConfiguration` handler never fires. Setting both is worse than setting only `applicationCategories`.

### 4.5 — ShieldConfiguration Does Not Fire for Category Blocks

**Result:** When using `shield.applicationCategories = .all()` or `.all(except:)`, the ShieldConfiguration extension binary is **not even loaded** by iOS. The system shows its default shield UI. ShieldConfiguration per-app handlers only fire for `shield.applications` entries — but those don't actually block anything.

This means ShieldConfiguration cannot be used as a name resolution channel when using category blocking (which is the only blocking method that works).

### 4.6 — ShieldAction Category Handler Has No App Identity

**Result:** The ShieldAction category handler *does* fire when a user taps a button on the shield, but it receives an `ActivityCategoryToken`, not an `ApplicationToken`. There is no way to know *which* app the user was trying to open from the category handler alone.

---

## Part 5: What Actually Works

### 5.1 — DeviceActivityReport Extension (Display-Only)

The DeviceActivityReport extension runs in a privileged context with access to the Screen Time data store. Inside the extension:

- `application.localizedDisplayName` returns real app names
- `application.bundleIdentifier` returns real bundle IDs
- Activity data can be iterated via `DeviceActivityResults`

**Limitation:** Data cannot leave the extension (see Part 3). Names can only be *displayed* inside the extension's own SwiftUI view, which is embedded in the main app but rendered in a separate process.

**Implementation:** Two report scenes:
- `NameResolverScene` — renders a "Known Apps" card showing resolved names directly in the child's home view
- `TokenProbeReportScene` — diagnostic view showing coverage statistics

The extension view is embedded in `ChildHomeView` with a minimum 80pt frame height (required for iOS to load the extension process). A `nameResolverEpoch` state variable forces re-evaluation when the app returns to foreground.

### 5.2 — Organic Mapping via Unlock Request Picker

When a child's app is blocked and they want more time:

1. Category shield appears → child taps "Ask for More Time"
2. ShieldAction category handler fires → sets a `unlockPickerPending` flag in App Group storage
3. Child opens Big Brother app → picker auto-opens (via `scenePhase` observer)
4. `FamilyActivityPicker` shows real app names to the child
5. Child selects the app they want → we get the `ApplicationToken`
6. Token + best-effort name stored in `PendingUnlockRequest` and synced to CloudKit
7. Parent sees the request and can approve/deny

**Name quality:** `localizedDisplayName` is still `nil` from the main app, so the name falls back to partial parsing of the token description or a generic "App" label. The parent can manually name the app when approving.

### 5.3 — ShieldAction Extension Can Write to App Group

Unlike DeviceActivityReport, the ShieldAction extension *can* write to App Group files and Keychain. However, the category handler receives no app identity (see 4.6), so it can only write the `LastShieldedApp` cache entry with whatever information it can infer:

1. Check if ShieldConfiguration cached a name for the last shielded app
2. If only one app is in the shield cache, assume it's that app
3. Otherwise, fall back to "an app"

This provides partial coverage — when a child hits a shield and taps through, we might learn the app name for future reference.

### 5.4 — ShieldConfiguration Can Resolve Names (But Only for Per-App Shields)

ShieldConfiguration extension can access `Application.localizedDisplayName` and write to App Group storage. It successfully caches token→name mappings.

**Catch:** It only fires for `shield.applications` entries, which don't actually block apps (see 4.1). Since we must use `shield.applicationCategories` for blocking, ShieldConfiguration never runs in practice.

### 5.5 — `FamilyActivitySelection(includeEntireCategory: true)`

When using `FamilyActivityPicker` with category selection enabled and `includeEntireCategory: true`, selecting categories expands to include all individual app tokens (observed: 159 tokens from 13 categories).

This is useful for building a complete token set but doesn't help with name resolution since `localizedDisplayName` is still `nil` from the main app.

---

## Part 6: Current Architecture

Given the constraints above, the app uses a multi-layer approach:

```
┌─────────────────────────────────────────────────────────┐
│                    Parent Device                         │
│  Sees: app names from unlock requests + manual naming    │
│  CloudKit: receives PendingUnlockRequest with best-      │
│           effort names                                   │
└─────────────────────────────────────────────────────────┘
                          ▲
                          │ CloudKit sync
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    Child Device                           │
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │ DeviceActivityReport │  │     Main App Process      │ │
│  │    (display-only)    │  │                            │ │
│  │                      │  │  • Token set from picker   │ │
│  │  CAN resolve names   │──│  • CANNOT resolve names    │ │
│  │  CANNOT export data  │  │  • Reads ShieldAction       │ │
│  │                      │  │    App Group writes        │ │
│  │  Rendered as embedded │  │  • Best-effort from unlock │ │
│  │  card in ChildHome   │  │    request flow            │ │
│  └──────────────────────┘  └──────────────────────────┘ │
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │  ShieldAction Ext    │  │  ShieldConfig Ext         │ │
│  │                      │  │                            │ │
│  │  CAN write App Group │  │  CAN resolve names        │ │
│  │  Category handler:   │  │  CAN write App Group      │ │
│  │   no app identity    │  │  BUT: never invoked for   │ │
│  │  Sets picker pending │  │   category blocks         │ │
│  └──────────────────────┘  └──────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Name Resolution Quality

| Source | Name Quality | Coverage |
|--------|-------------|----------|
| DeviceActivityReport display | Real app names | Apps with Screen Time usage history |
| Unlock request picker | "App" fallback (localizedDisplayName nil) | Only apps child requests |
| ShieldAction cache | Partial / inferred | Only when shield is tapped |
| Parent manual naming | Perfect (human input) | Only apps parent names |

---

## Key Takeaways

1. **Apple intentionally prevents token→name extraction** outside privileged extension contexts. This is a security/privacy design decision, not a bug.

2. **The one extension that CAN resolve names (DeviceActivityReport) is the most sandboxed** — it cannot write to files, UserDefaults, Keychain, or communicate via URL schemes. Every outbound channel is blocked.

3. **The extensions that CAN write data (ShieldAction, ShieldConfiguration) either don't have app identity or don't fire** for the only blocking method that works (category blocking).

4. **Category blocking is the only functional blocking method**, but it strips app identity from all handler callbacks.

5. **There is no fully automated solution.** The best achievable approach combines organic mapping (unlock requests build up a cache over time) with display-only resolution (DeviceActivityReport shows names on the child device) and manual parent naming.

6. **iOS 26 (announced WWDC 2025) adds PermissionKit** but makes no changes to the Screen Time API frameworks. This problem remains unsolved by Apple as of the latest SDK.
