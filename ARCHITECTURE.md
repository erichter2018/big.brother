# Big.Brother — Phase 1 Architecture

## Table of Contents

1. [Technical Planning Summary](#1-technical-planning-summary)
2. [System Architecture](#2-system-architecture)
3. [Xcode Project Structure](#3-xcode-project-structure)
4. [Folder / Module Structure](#4-folder--module-structure)
5. [Core Domain Models](#5-core-domain-models)
6. [Key Services and Protocols](#6-key-services-and-protocols)
7. [CloudKit Schema Proposal](#7-cloudkit-schema-proposal)
8. [Parent vs Child Role Model](#8-parent-vs-child-role-model)
9. [Enrollment Architecture](#9-enrollment-architecture)
10. [Command Architecture](#10-command-architecture)
11. [Policy Engine Architecture](#11-policy-engine-architecture)
12. [Reliability Architecture](#12-reliability-architecture)
13. [Security Architecture](#13-security-architecture)
14. [Extension Responsibilities](#14-extension-responsibilities)
15. [Risks and Tricky Areas](#15-risks-and-tricky-areas)
16. [Phase 2 Implementation Order](#16-phase-2-implementation-order)

---

## 1. Technical Planning Summary

### 1.1 Key Technical Challenges

**A. Family Controls without Family Sharing.**
Apple's Screen Time APIs offer two authorization modes: `.child` (requires Family Sharing) and `.individual` (iOS 16+, user self-authorizes). Since this family exceeds Family Sharing capacity, we must use `.individual` authorization. The parent physically authorizes FamilyControls on the child's device during enrollment. Trade-off: a savvy child could revoke authorization in Settings. We must detect and alert on this.

**B. Shared Apple ID across parent and child devices.**
Some child devices are signed into a parent's Apple ID. This means CloudKit private-database records are shared between parent and child — which is actually convenient for sync, but means Apple ID cannot serve as identity. We must use app-managed identity: enrollment-based device IDs and child profiles, stored in Keychain and validated by the app itself.

**C. App token locality.**
`ApplicationToken` and `ActivityCategoryToken` from FamilyControls are opaque, device-local tokens. A token obtained on one device cannot be used on another. This means "Always Allowed" app selections must happen on the child device itself (using `FamilyActivityPicker`), not remotely from the parent's device. Category-level controls (block all Games, all Social) are more universal and can be commanded remotely.

**D. Extension constraints.**
`DeviceActivityMonitor`, `ShieldConfigurationDataSource`, and `ShieldActionDelegate` extensions run in separate processes with extreme resource limits. They cannot make network calls. They must read all policy from App Group shared storage. The main app is responsible for keeping shared storage up to date.

**E. Offline enforcement.**
The child device must enforce policy even without internet. Policy must be cached locally in App Group storage. The local parent PIN unlock must work offline, with the event logged and synced later.

**F. Role security.**
A child must not be able to switch to parent mode. The device role must be stored in Keychain (tamper-resistant) and parent access must require biometric + PIN authentication every time.

### 1.2 Major System Components

| Component              | Responsibility                                                    |
|------------------------|-------------------------------------------------------------------|
| **Core Domain**        | Models, enums, ID types — shared across all targets               |
| **Policy Engine**      | Resolves intended mode + schedule + overrides → effective policy   |
| **Enforcement Layer**  | Applies effective policy via ManagedSettings framework             |
| **Command System**     | Queue, dispatch, receipt, reconciliation for remote commands       |
| **Sync Layer**         | CloudKit operations, subscriptions, polling                       |
| **Enrollment System**  | Code generation, device registration, profile linking             |
| **Auth / Security**    | Biometric + PIN auth, Keychain, role gating                       |
| **Shared Storage**     | App Group read/write for cross-target policy state                |
| **Heartbeat**          | Periodic device check-in for parent dashboard                     |
| **Event Logger**       | Structured log of enforcement events, synced to CloudKit          |
| **Extensions**         | DeviceActivityMonitor, ShieldConfiguration, ShieldAction          |

### 1.3 Module Division

```
┌─────────────────────────────────────────────────────────┐
│                   BigBrotherApp                          │
│  (Main app target — UI, CloudKit, enrollment, auth)     │
│                                                         │
│  Imports: BigBrotherCore, FamilyControls,                │
│           ManagedSettings, CloudKit                      │
└────────────────────────┬────────────────────────────────┘
                         │ depends on
┌────────────────────────▼────────────────────────────────┐
│                  BigBrotherCore                          │
│  (Local Swift Package — shared by all targets)          │
│                                                         │
│  Pure Swift + Foundation only.                          │
│  Models, PolicyResolver, SharedStorage, Security,       │
│  Constants. NO FamilyControls/ManagedSettings imports.  │
└────────────────────────┬────────────────────────────────┘
                         │ depended on by
          ┌──────────────┼──────────────┬─────────────────┐
          │              │              │                  │
   ┌──────▼──────┐ ┌────▼─────┐ ┌─────▼──────┐ ┌────────▼────────┐
   │  BBMonitor  │ │ BBShield │ │BBShieldAct │ │  BigBrotherApp  │
   │ (Extension) │ │(Extension)│ │(Extension) │ │   (Main App)    │
   └─────────────┘ └──────────┘ └────────────┘ └─────────────────┘
```

**Why BigBrotherCore avoids FamilyControls imports:**
`ApplicationToken` and `ActivityCategoryToken` are device-local opaque types. The core module stores them as serialized `Data` blobs. Only the targets that interact with the FamilyControls framework decode these blobs into native tokens. This keeps the core module pure, testable, and framework-independent.

---

## 2. System Architecture

### 2.1 High-Level Data Flow

```
PARENT DEVICE                        CLOUDKIT                         CHILD DEVICE
═══════════════                      ════════                         ════════════

Parent taps
"Lock Simon"
       │
       ▼
┌──────────────┐     write      ┌──────────────┐   subscription/   ┌──────────────┐
│ CloudKit     │ ──────────────▶│ RemoteCommand │   poll trigger   │ CloudKit     │
│ Service      │                │ record        │ ────────────────▶│ Service      │
└──────────────┘                └──────────────┘                   └──────┬───────┘
                                                                         │
                                                                         ▼
                                                                   ┌──────────────┐
                                                                   │ Command      │
                                                                   │ Processor    │
                                                                   └──────┬───────┘
                                                                         │
                                                                         ▼
                                                                   ┌──────────────┐
                                                                   │ Policy       │
                                                                   │ Resolver     │
                                                                   └──────┬───────┘
                                                                         │
                                                                   ┌─────▼────────┐
                                                                   │ App Group    │
                                                                   │ Storage      │◀── Extensions
                                                                   └─────┬────────┘    read here
                                                                         │
                                                                         ▼
                                                                   ┌──────────────┐
                                                                   │ Enforcement  │
                                                                   │ Service      │
                                                                   │ (Managed     │
                                                                   │  Settings)   │
                                                                   └──────┬───────┘
                                                                         │
                                                                         ▼
                                                                   ┌──────────────┐
                                                                   │ Command      │
                                write receipt                      │ Receipt      │
                                ◀──────────────────────────────────│              │
                                                                   └──────────────┘
```

### 2.2 Child Device Internal Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CHILD DEVICE                                  │
│                                                                     │
│  ┌─────────────┐    ┌──────────────┐    ┌──────────────────────┐   │
│  │ CloudKit    │───▶│ Command      │───▶│ PolicyResolver       │   │
│  │ Sync        │    │ Processor    │    │                      │   │
│  └─────────────┘    └──────────────┘    │ Inputs:              │   │
│                                         │  - base mode         │   │
│  ┌─────────────┐                        │  - active schedule   │   │
│  │ Schedule    │───────────────────────▶│  - temp unlock       │   │
│  │ Manager     │                        │  - always-allowed    │   │
│  └─────────────┘                        │  - capabilities      │   │
│                                         └──────────┬───────────┘   │
│                                                    │               │
│                                                    ▼               │
│                                         ┌──────────────────────┐   │
│                                         │  PolicySnapshot      │   │
│                ┌────────────────────────▶│  (App Group JSON)    │   │
│                │                        └──────────┬───────────┘   │
│                │                                   │               │
│  ┌─────────────┴────┐                              ▼               │
│  │ DeviceActivity   │                   ┌──────────────────────┐   │
│  │ Monitor Ext.     │                   │  EnforcementService  │   │
│  │ (reads snapshot, │                   │  (ManagedSettings    │   │
│  │  applies shield) │                   │   Store updates)     │   │
│  └──────────────────┘                   └──────────────────────┘   │
│                                                                     │
│  ┌──────────────────┐    ┌──────────────────┐                      │
│  │ Shield Config    │    │ Shield Action    │                      │
│  │ Extension        │    │ Extension        │                      │
│  │ (reads snapshot  │    │ (reads snapshot, │                      │
│  │  for custom UI)  │    │  handles "ask    │                      │
│  └──────────────────┘    │  for time" tap)  │                      │
│                          └──────────────────┘                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Xcode Project Structure

### 3.1 Targets

| Target                  | Type                            | Bundle ID                           |
|-------------------------|---------------------------------|-------------------------------------|
| BigBrother              | iOS App                         | `com.bigbrother.app`                |
| BigBrotherMonitor       | DeviceActivityMonitor Extension | `com.bigbrother.app.monitor`        |
| BigBrotherShield        | ShieldConfiguration Extension   | `com.bigbrother.app.shield`         |
| BigBrotherShieldAction  | ShieldAction Extension          | `com.bigbrother.app.shield-action`  |
| BigBrotherCore          | Local Swift Package             | (no bundle ID — library)            |
| BigBrotherCoreTests     | Unit Test Bundle                | `com.bigbrother.core-tests`         |

### 3.2 Deployment Target

**iOS 17.0+** (iPadOS 17.0+)

Rationale: iOS 17 gives us `@Observable`, improved SwiftUI, `SwiftData` (optional), and mature FamilyControls APIs. In March 2026, iOS 17 adoption is effectively universal.

### 3.3 Capabilities & Entitlements

| Capability                   | BigBrother App | Monitor Ext | Shield Ext | ShieldAction Ext |
|------------------------------|:--------------:|:-----------:|:----------:|:----------------:|
| Family Controls              | Yes            | Yes         | Yes        | Yes              |
| App Groups                   | Yes            | Yes         | Yes        | Yes              |
| CloudKit (iCloud)            | Yes            | —           | —          | —                |
| Push Notifications           | Yes            | —           | —          | —                |
| Background Modes             | Yes (fetch, remote-notification) | — | — | —          |
| Keychain Sharing             | Yes            | Yes         | —          | —                |

**App Group identifier:** `group.com.bigbrother.shared`

**CloudKit container:** `iCloud.com.bigbrother.app`

**Keychain access group:** `$(TeamIdentifierPrefix)com.bigbrother.shared`

---

## 4. Folder / Module Structure

```
BigBrother/
├── BigBrother.xcodeproj
│
├── BigBrotherCore/                              # Local Swift Package
│   ├── Package.swift
│   ├── Sources/BigBrotherCore/
│   │   ├── Models/
│   │   │   ├── Identifiers.swift                # FamilyID, ChildProfileID, DeviceID
│   │   │   ├── ChildProfile.swift
│   │   │   ├── ChildDevice.swift
│   │   │   ├── LockMode.swift
│   │   │   ├── Policy.swift
│   │   │   ├── EffectivePolicy.swift
│   │   │   ├── RemoteCommand.swift
│   │   │   ├── CommandReceipt.swift
│   │   │   ├── DeviceHeartbeat.swift
│   │   │   ├── EventLogEntry.swift
│   │   │   ├── EnrollmentInvite.swift
│   │   │   └── Schedule.swift
│   │   │
│   │   ├── Policy/
│   │   │   ├── PolicyResolver.swift             # Pure: inputs → EffectivePolicy
│   │   │   └── CapabilityReport.swift           # What can/can't be enforced
│   │   │
│   │   ├── Storage/
│   │   │   ├── SharedStorageProtocol.swift       # Protocol for App Group R/W
│   │   │   ├── AppGroupStorage.swift            # Concrete implementation
│   │   │   ├── PolicySnapshot.swift             # Versioned policy on disk
│   │   │   └── StorageKeys.swift
│   │   │
│   │   ├── Security/
│   │   │   ├── KeychainProtocol.swift
│   │   │   ├── KeychainManager.swift
│   │   │   ├── PINHasher.swift                  # bcrypt hashing
│   │   │   └── DeviceRole.swift                 # .parent / .child / .unconfigured
│   │   │
│   │   └── Constants/
│   │       ├── AppConstants.swift               # App Group ID, container ID
│   │       └── Defaults.swift                   # Default essential apps list, etc.
│   │
│   └── Tests/BigBrotherCoreTests/
│       ├── PolicyResolverTests.swift
│       ├── PINHasherTests.swift
│       └── AppGroupStorageTests.swift
│
├── BigBrotherApp/                               # Main App Target
│   ├── App/
│   │   ├── BigBrotherApp.swift                  # @main, scene setup
│   │   ├── AppState.swift                       # @Observable root state
│   │   └── RootRouter.swift                     # Routes: onboarding / parent / child
│   │
│   ├── Services/
│   │   ├── CloudKit/
│   │   │   ├── CloudKitService.swift            # CRUD, subscriptions, fetch
│   │   │   ├── CKRecordMapping.swift            # Model ↔ CKRecord conversion
│   │   │   └── SyncCoordinator.swift            # Orchestrates full sync cycle
│   │   │
│   │   ├── Auth/
│   │   │   ├── AuthService.swift                # Biometric + PIN authentication
│   │   │   └── ParentGate.swift                 # SwiftUI ViewModifier for gating
│   │   │
│   │   ├── Enforcement/
│   │   │   ├── EnforcementService.swift         # Applies policy via ManagedSettings
│   │   │   ├── FamilyControlsManager.swift      # Authorization state management
│   │   │   └── ScheduleManager.swift            # DeviceActivitySchedule registration
│   │   │
│   │   ├── Enrollment/
│   │   │   ├── EnrollmentService.swift          # Create/validate enrollment codes
│   │   │   └── CodeGenerator.swift              # Generates enrollment codes
│   │   │
│   │   ├── CommandProcessor.swift               # Ingests and applies remote commands
│   │   ├── HeartbeatService.swift               # Periodic heartbeat publisher
│   │   └── EventLogger.swift                    # Log events, queue for sync
│   │
│   ├── Features/
│   │   ├── Onboarding/
│   │   │   ├── OnboardingView.swift             # First-launch role selection
│   │   │   ├── ParentSetupView.swift            # PIN creation, family setup
│   │   │   └── ChildEnrollView.swift            # Enrollment code entry
│   │   │
│   │   ├── Parent/
│   │   │   ├── ParentDashboardView.swift        # Overview of all children/devices
│   │   │   ├── ChildCardView.swift              # Summary card per child
│   │   │   ├── ChildDetailView.swift            # Child profile detail
│   │   │   ├── DeviceDetailView.swift           # Per-device status and controls
│   │   │   ├── PolicyEditorView.swift           # Mode selection, app picker
│   │   │   ├── EnrollDeviceView.swift           # Generate enrollment code
│   │   │   └── ParentSettingsView.swift         # PIN change, admin settings
│   │   │
│   │   └── Child/
│   │       ├── ChildHomeView.swift              # Status display, time remaining
│   │       └── LocalUnlockView.swift            # Parent PIN entry on child device
│   │
│   └── Resources/
│       ├── Assets.xcassets
│       ├── Info.plist
│       └── BigBrother.entitlements
│
├── BigBrotherMonitor/                           # DeviceActivityMonitor Extension
│   ├── BigBrotherMonitorExtension.swift
│   ├── Info.plist
│   └── BigBrotherMonitor.entitlements
│
├── BigBrotherShield/                            # ShieldConfiguration Extension
│   ├── BigBrotherShieldExtension.swift
│   ├── Info.plist
│   └── BigBrotherShield.entitlements
│
└── BigBrotherShieldAction/                      # ShieldAction Extension
    ├── BigBrotherShieldActionExtension.swift
    ├── Info.plist
    └── BigBrotherShieldAction.entitlements
```

---

## 5. Core Domain Models

All models live in `BigBrotherCore` and are `Codable`, `Sendable`, and `Equatable`.

### 5.1 Identifiers

```swift
// Identifiers.swift

/// Unique family identifier — generated once during parent setup.
/// Acts as the partition key for all CloudKit records.
struct FamilyID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    static func generate() -> FamilyID {
        FamilyID(rawValue: UUID().uuidString)
    }
}

/// Unique child profile identifier.
struct ChildProfileID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    static func generate() -> ChildProfileID {
        ChildProfileID(rawValue: UUID().uuidString)
    }
}

/// Unique device identifier — generated on enrollment, stored in Keychain.
struct DeviceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    static func generate() -> DeviceID {
        DeviceID(rawValue: UUID().uuidString)
    }
}
```

### 5.2 ChildProfile

```swift
// ChildProfile.swift

struct ChildProfile: Codable, Sendable, Identifiable, Equatable {
    let id: ChildProfileID
    let familyID: FamilyID
    var name: String
    var avatarName: String?

    /// Serialized app tokens — device-local, but synced as Data for backup.
    /// Decoded to ApplicationToken only on the device that created them.
    var alwaysAllowedTokensData: Data?

    /// Category-level always-allowed (universal across devices).
    var alwaysAllowedCategories: Set<String> // e.g., "productivity", "education"

    let createdAt: Date
    var updatedAt: Date
}
```

### 5.3 ChildDevice

```swift
// ChildDevice.swift

struct ChildDevice: Codable, Sendable, Identifiable, Equatable {
    let id: DeviceID
    let childProfileID: ChildProfileID
    let familyID: FamilyID

    var displayName: String          // e.g., "Simon's iPad"
    var modelIdentifier: String      // e.g., "iPad14,1"
    var osVersion: String
    let enrolledAt: Date
    var lastHeartbeat: Date?

    /// The mode most recently confirmed by the device.
    var confirmedMode: LockMode?

    /// The policy version most recently confirmed by the device.
    var confirmedPolicyVersion: Int64?

    /// Whether FamilyControls authorization is active on this device.
    var familyControlsAuthorized: Bool

    var isOnline: Bool {
        guard let hb = lastHeartbeat else { return false }
        return Date().timeIntervalSince(hb) < 600 // 10 min
    }
}
```

### 5.4 LockMode

```swift
// LockMode.swift

enum LockMode: String, Codable, Sendable, CaseIterable {
    case unlocked
    case dailyMode       // block all except allowed list
    case fullLockdown    // block everything possible
    case essentialOnly   // narrow essential set only
}
```

### 5.5 Policy & EffectivePolicy

```swift
// Policy.swift

/// The intended policy for a device, as set by the parent.
struct Policy: Codable, Sendable, Equatable {
    let targetDeviceID: DeviceID
    var mode: LockMode
    var temporaryUnlockUntil: Date?
    var activeScheduleID: UUID?
    var version: Int64
    var updatedAt: Date
}
```

```swift
// EffectivePolicy.swift

/// The resolved policy after considering mode, schedule, temp unlock,
/// always-allowed, and capability limitations.
struct EffectivePolicy: Codable, Sendable, Equatable {
    let resolvedMode: LockMode
    let isTemporaryUnlock: Bool
    let temporaryUnlockExpiresAt: Date?

    /// Serialized tokens for apps that should be shielded.
    /// nil means "no shielding" (unlocked mode).
    /// empty Data means "shield everything" (full lockdown).
    let shieldedCategoriesData: Data?
    let allowedAppTokensData: Data?

    let warnings: [CapabilityWarning]
    let policyVersion: Int64
    let resolvedAt: Date
}

enum CapabilityWarning: String, Codable, Sendable {
    case familyControlsNotAuthorized
    case someSystemAppsCannotBeBlocked
    case scheduleMayNotFireIfAppKilled
    case offlineUsingCachedPolicy
    case tokensMissingForDevice
}
```

### 5.6 RemoteCommand & CommandReceipt

```swift
// RemoteCommand.swift

struct RemoteCommand: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let familyID: FamilyID
    let target: CommandTarget
    let action: CommandAction
    let issuedBy: String          // parent device ID or name
    let issuedAt: Date
    let expiresAt: Date?
    var status: CommandStatus
}

enum CommandTarget: Codable, Sendable, Equatable {
    case device(DeviceID)
    case child(ChildProfileID)
    case allDevices
}

enum CommandAction: Codable, Sendable, Equatable {
    case setMode(LockMode)
    case temporaryUnlock(durationSeconds: Int)
    case updatePolicy(Policy)
    case requestHeartbeat
    case unenroll
}

enum CommandStatus: String, Codable, Sendable {
    case pending
    case delivered
    case applied
    case failed
    case expired
}
```

```swift
// CommandReceipt.swift

struct CommandReceipt: Codable, Sendable, Equatable {
    let commandID: UUID
    let deviceID: DeviceID
    let familyID: FamilyID
    let status: CommandStatus
    let appliedAt: Date?
    let failureReason: String?
}
```

### 5.7 DeviceHeartbeat

```swift
// DeviceHeartbeat.swift

struct DeviceHeartbeat: Codable, Sendable {
    let deviceID: DeviceID
    let familyID: FamilyID
    let timestamp: Date
    let currentMode: LockMode
    let policyVersion: Int64
    let familyControlsAuthorized: Bool
    let batteryLevel: Double?
    let isCharging: Bool?
}
```

### 5.8 EventLogEntry

```swift
// EventLogEntry.swift

struct EventLogEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let deviceID: DeviceID
    let familyID: FamilyID
    let eventType: EventType
    let details: String?
    let timestamp: Date
    var synced: Bool
}

enum EventType: String, Codable, Sendable {
    case modeChanged
    case commandApplied
    case commandFailed
    case localPINUnlock
    case enrollmentCompleted
    case enrollmentRevoked
    case familyControlsAuthChanged
    case heartbeatSent
    case deviceOffline
    case scheduleTriggered
    case temporaryUnlockExpired
    case appLaunchBlocked
}
```

### 5.9 EnrollmentInvite

```swift
// EnrollmentInvite.swift

struct EnrollmentInvite: Codable, Sendable {
    let code: String               // 8-char alphanumeric
    let familyID: FamilyID
    let childProfileID: ChildProfileID
    let createdAt: Date
    let expiresAt: Date            // 30 minutes after creation
    var used: Bool
    var usedByDeviceID: DeviceID?
}
```

### 5.10 Schedule

```swift
// Schedule.swift

struct Schedule: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let childProfileID: ChildProfileID
    let familyID: FamilyID
    var name: String               // e.g., "School Hours"
    var mode: LockMode             // mode to apply during schedule
    var daysOfWeek: Set<DayOfWeek>
    var startTime: DayTime         // e.g., 08:00
    var endTime: DayTime           // e.g., 15:00
    var isActive: Bool
    var updatedAt: Date
}

struct DayTime: Codable, Sendable, Equatable, Comparable {
    let hour: Int    // 0-23
    let minute: Int  // 0-59
}

enum DayOfWeek: Int, Codable, Sendable, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
}
```

### 5.11 DeviceRole

```swift
// DeviceRole.swift

/// Stored in Keychain. Determines what UI the app shows.
enum DeviceRole: String, Codable, Sendable {
    case unconfigured  // first launch
    case parent
    case child
}

/// Full enrollment state for a child device. Stored in Keychain.
struct ChildEnrollmentState: Codable, Sendable {
    let deviceID: DeviceID
    let childProfileID: ChildProfileID
    let familyID: FamilyID
    let enrolledAt: Date
}

/// Parent state. Stored in Keychain.
struct ParentState: Codable, Sendable {
    let familyID: FamilyID
    let setupAt: Date
}
```

---

## 6. Key Services and Protocols

### 6.1 CloudKitService

```swift
// CloudKitService.swift

protocol CloudKitServiceProtocol: Sendable {
    // Child profiles
    func fetchChildProfiles(familyID: FamilyID) async throws -> [ChildProfile]
    func saveChildProfile(_ profile: ChildProfile) async throws
    func deleteChildProfile(_ id: ChildProfileID) async throws

    // Devices
    func fetchDevices(familyID: FamilyID) async throws -> [ChildDevice]
    func fetchDevices(childProfileID: ChildProfileID) async throws -> [ChildDevice]
    func saveDevice(_ device: ChildDevice) async throws
    func deleteDevice(_ id: DeviceID) async throws

    // Commands
    func pushCommand(_ command: RemoteCommand) async throws
    func fetchPendingCommands(deviceID: DeviceID) async throws -> [RemoteCommand]
    func fetchPendingCommands(childProfileID: ChildProfileID) async throws -> [RemoteCommand]
    func fetchGlobalCommands(familyID: FamilyID) async throws -> [RemoteCommand]
    func saveReceipt(_ receipt: CommandReceipt) async throws

    // Enrollment
    func saveEnrollmentInvite(_ invite: EnrollmentInvite) async throws
    func fetchEnrollmentInvite(code: String) async throws -> EnrollmentInvite?
    func markInviteUsed(code: String, deviceID: DeviceID) async throws

    // Heartbeat
    func sendHeartbeat(_ heartbeat: DeviceHeartbeat) async throws
    func fetchLatestHeartbeats(familyID: FamilyID) async throws -> [DeviceHeartbeat]

    // Events
    func syncEventLogs(_ entries: [EventLogEntry]) async throws
    func fetchEventLogs(familyID: FamilyID, since: Date) async throws -> [EventLogEntry]

    // Policy
    func savePolicy(_ policy: Policy) async throws
    func fetchPolicy(deviceID: DeviceID) async throws -> Policy?

    // Subscriptions
    func setupSubscriptions(familyID: FamilyID, deviceID: DeviceID?) async throws
}
```

### 6.2 AuthService

```swift
// AuthService.swift

protocol AuthServiceProtocol {
    /// Attempt biometric auth, fall back to PIN.
    func authenticateParent() async throws -> Bool

    /// Validate PIN only (for local unlock on child device).
    func validatePIN(_ pin: String) -> Bool

    /// Set or change the parent PIN.
    func setPIN(_ pin: String) throws

    /// Whether biometric auth is available.
    var biometricAvailable: Bool { get }
}
```

### 6.3 EnforcementService

```swift
// EnforcementService.swift

protocol EnforcementServiceProtocol {
    /// Apply the given effective policy to ManagedSettings stores.
    func apply(_ policy: EffectivePolicy) throws

    /// Clear all restrictions (unlocked mode).
    func clearAllRestrictions() throws

    /// Current FamilyControls authorization status.
    var authorizationStatus: FamilyControlsAuthorizationStatus { get }

    /// Request FamilyControls individual authorization.
    func requestAuthorization() async throws
}

enum FamilyControlsAuthorizationStatus: Sendable {
    case notDetermined
    case authorized
    case denied
    case revoked
}
```

### 6.4 PolicyResolver

```swift
// PolicyResolver.swift

/// Pure function — no side effects, no framework dependencies.
/// Lives in BigBrotherCore.
struct PolicyResolver {
    /// Resolve the effective policy from all inputs.
    static func resolve(
        basePolicy: Policy,
        schedule: Schedule?,
        currentTime: Date,
        alwaysAllowedTokensData: Data?,
        alwaysAllowedCategories: Set<String>,
        capabilities: DeviceCapabilities
    ) -> EffectivePolicy
}

struct DeviceCapabilities: Codable, Sendable {
    let familyControlsAuthorized: Bool
    let canBlockSystemApps: Bool // always false for most system apps
    let isOnline: Bool
}
```

### 6.5 SharedStorage

```swift
// SharedStorageProtocol.swift

/// Protocol for App Group shared storage.
/// Implemented by AppGroupStorage. Used by main app and all extensions.
protocol SharedStorageProtocol: Sendable {
    func readPolicySnapshot() -> PolicySnapshot?
    func writePolicySnapshot(_ snapshot: PolicySnapshot) throws

    func readDeviceRole() -> DeviceRole
    func readEnrollmentState() -> ChildEnrollmentState?

    func readShieldConfiguration() -> ShieldConfig?
    func writeShieldConfiguration(_ config: ShieldConfig) throws

    func appendEventLog(_ entry: EventLogEntry) throws
    func readPendingEventLogs() -> [EventLogEntry]
    func clearSyncedEventLogs(ids: Set<UUID>) throws
}
```

```swift
// PolicySnapshot.swift

/// Versioned snapshot of the currently active policy.
/// Written by the main app. Read by the main app and all extensions.
struct PolicySnapshot: Codable, Sendable {
    let effectivePolicy: EffectivePolicy
    let childProfile: ChildProfile?
    let writtenAt: Date
    let writerVersion: Int // app build number for debugging
}
```

### 6.6 CommandProcessor

```swift
// CommandProcessor.swift

/// Runs on child device. Fetches, validates, and applies incoming commands.
protocol CommandProcessorProtocol {
    /// Poll for new commands and process them.
    func processIncomingCommands() async throws

    /// Process a single command (called from poll or push handler).
    func process(_ command: RemoteCommand) async throws -> CommandReceipt
}
```

### 6.7 HeartbeatService

```swift
// HeartbeatService.swift

protocol HeartbeatServiceProtocol {
    /// Start periodic heartbeat publishing.
    func startHeartbeat()

    /// Stop heartbeat (e.g., when app is about to be suspended).
    func stopHeartbeat()

    /// Send one heartbeat immediately.
    func sendNow() async throws
}
```

### 6.8 EventLogger

```swift
// EventLogger.swift

protocol EventLoggerProtocol {
    /// Log an event locally. It will be synced to CloudKit later.
    func log(_ type: EventType, details: String?)

    /// Sync all pending events to CloudKit.
    func syncPendingEvents() async throws
}
```

---

## 7. CloudKit Schema Proposal

### 7.1 Database Choice

**Public database** with `familyID` as a partition key on every record.

Rationale:
- Works regardless of which Apple ID is signed in on each device.
- No CKShare complexity for cross-Apple-ID access.
- The `familyID` is a UUID — computationally infeasible to guess.
- Acceptable for a single-family app. If App Store distribution is needed later, migrate to private database + CKShare.

### 7.2 Record Types

All records include a `familyID` field (indexed) for partition filtering.

```
RecordType: BBFamily
────────────────────
  familyID          : String  (indexed, unique)
  familyName        : String
  createdAt         : Date


RecordType: BBChildProfile
──────────────────────────
  profileID         : String  (indexed)
  familyID          : String  (indexed)
  name              : String
  avatarName        : String?
  alwaysAllowedCategoriesJSON : String    // JSON-encoded Set<String>
  createdAt         : Date
  updatedAt         : Date


RecordType: BBChildDevice
─────────────────────────
  deviceID          : String  (indexed)
  profileID         : String  (indexed)
  familyID          : String  (indexed)
  displayName       : String
  modelIdentifier   : String
  osVersion         : String
  enrolledAt        : Date
  familyControlsOK  : Int64  (0 or 1)


RecordType: BBPolicy
────────────────────
  deviceID          : String  (indexed)
  familyID          : String  (indexed)
  mode              : String
  tempUnlockUntil   : Date?
  scheduleID        : String?
  version           : Int64
  updatedAt         : Date


RecordType: BBRemoteCommand
───────────────────────────
  commandID         : String  (indexed)
  familyID          : String  (indexed)
  targetType        : String  ("device" | "child" | "all")
  targetID          : String? (DeviceID or ChildProfileID, nil for "all")
  actionJSON        : String  (JSON-encoded CommandAction)
  issuedBy          : String
  issuedAt          : Date
  expiresAt         : Date?
  status            : String


RecordType: BBCommandReceipt
────────────────────────────
  commandID         : String  (indexed)
  deviceID          : String  (indexed)
  familyID          : String  (indexed)
  status            : String
  appliedAt         : Date?
  failureReason     : String?


RecordType: BBHeartbeat
───────────────────────
  deviceID          : String  (indexed)
  familyID          : String  (indexed)
  timestamp         : Date
  currentMode       : String
  policyVersion     : Int64
  fcAuthorized      : Int64
  batteryLevel      : Double?
  isCharging        : Int64?


RecordType: BBEventLog
──────────────────────
  eventID           : String  (indexed)
  deviceID          : String  (indexed)
  familyID          : String  (indexed)
  eventType         : String
  details           : String?
  timestamp         : Date


RecordType: BBEnrollmentInvite
──────────────────────────────
  code              : String  (indexed)
  familyID          : String  (indexed)
  profileID         : String  (indexed)
  expiresAt         : Date
  used              : Int64   (0 or 1)
  usedByDeviceID    : String?
```

### 7.3 CloudKit Subscriptions

The child device subscribes to:

| Subscription                    | Predicate                                              | Purpose                           |
|---------------------------------|--------------------------------------------------------|-----------------------------------|
| `commands-for-device`           | `targetType = "device" AND targetID = {myDeviceID} AND status = "pending"` | Commands aimed at this device     |
| `commands-for-child`            | `targetType = "child" AND targetID = {myChildProfileID} AND status = "pending"` | Commands aimed at this child      |
| `commands-global`               | `targetType = "all" AND familyID = {myFamilyID} AND status = "pending"` | Global commands                   |
| `policy-for-device`             | `deviceID = {myDeviceID}`                              | Policy updates                    |

The parent device subscribes to:

| Subscription                    | Predicate                                              | Purpose                           |
|---------------------------------|--------------------------------------------------------|-----------------------------------|
| `receipts`                      | `familyID = {myFamilyID}`                              | Command acknowledgements          |
| `heartbeats`                    | `familyID = {myFamilyID}`                              | Device online status              |
| `events`                        | `familyID = {myFamilyID}`                              | Event log (especially local unlocks) |

### 7.4 CloudKit Operations Strategy

- **Writes:** Use `CKModifyRecordsOperation` with `.changedKeys` save policy.
- **Fetches:** Use `CKQueryOperation` filtered by `familyID` + relevant fields.
- **Conflict resolution:** Last-writer-wins for policy records (higher `version` wins). For commands, status transitions are monotonic: pending → delivered → applied/failed.
- **Heartbeat:** Upsert pattern — `CKModifyRecordsOperation` with `recordID` = `deviceID` so each device has exactly one heartbeat record that gets updated in place.

---

## 8. Parent vs Child Role Model

### 8.1 Role Determination

```
App Launch
    │
    ▼
Read DeviceRole from Keychain
    │
    ├── .unconfigured ──────▶ OnboardingView
    │                           ├── "Set Up as Parent" ──▶ ParentSetupView
    │                           └── "Enroll as Child"  ──▶ ChildEnrollView
    │
    ├── .parent ────────────▶ Require biometric/PIN auth
    │                           │
    │                           ├── success ──▶ ParentDashboardView
    │                           └── failure ──▶ Lock screen (retry)
    │
    └── .child ─────────────▶ ChildHomeView (no auth needed)
                                  │
                                  └── "Parent Unlock" button
                                        │
                                        ▼
                                  LocalUnlockView (PIN entry)
                                        │
                                        ├── valid PIN ──▶ Temporary unlock
                                        │                  (does NOT show parent UI)
                                        └── invalid   ──▶ Denied
```

### 8.2 Role Storage

| Data                     | Storage            | Why                                                  |
|--------------------------|--------------------|------------------------------------------------------|
| `DeviceRole`             | Keychain           | Tamper-resistant, survives app reinstall if Keychain not cleared |
| `ChildEnrollmentState`   | Keychain           | Contains deviceID, familyID — must be secure         |
| `ParentState`            | Keychain           | Contains familyID                                    |
| `parentPINHash`          | Keychain           | bcrypt hash, never stored in plaintext               |
| `parentPINSalt`          | Keychain           | Salt for PIN hash                                    |

### 8.3 Role Security Invariants

1. **A child device NEVER shows parent dashboard UI.** The `RootRouter` checks Keychain role. There is no "enter parent mode" on a child device.
2. **Local parent unlock on a child device** uses `LocalUnlockView` which accepts a PIN, validates it against the stored hash, and temporarily suspends enforcement. It does not change `DeviceRole` or show admin screens.
3. **Parent mode requires biometric or PIN auth** on every app launch (or after a configurable inactivity timeout, e.g., 5 minutes).
4. **Role change requires factory reset.** To change a child device to a parent device, the user must delete the app, clear Keychain, and re-set up. There is no in-app role switch.

### 8.4 ParentGate ViewModifier

The main app uses a SwiftUI `ViewModifier` to gate parent-only screens:

```swift
// ParentGate.swift — sketch only

struct ParentGate: ViewModifier {
    @State private var isAuthenticated = false
    let authService: AuthServiceProtocol

    func body(content: Content) -> some View {
        if isAuthenticated {
            content
        } else {
            AuthPromptView(authService: authService) {
                isAuthenticated = true
            }
        }
    }
}
```

---

## 9. Enrollment Architecture

### 9.1 Flow

```
PARENT DEVICE                      CLOUDKIT                      CHILD DEVICE
═══════════                        ════════                      ════════════

1. Parent creates ChildProfile
   (name: "Simon")
       │
       ▼
2. Parent taps "Add Device"
   → CodeGenerator creates
     8-char code (e.g., "A3K9M2X7")
   → ExpiresAt = now + 30min
       │
       ▼
3. Save BBEnrollmentInvite ─────▶ BBEnrollmentInvite record
                                  code: "A3K9M2X7"
                                  familyID: ...
                                  profileID: simon-id
                                  expiresAt: +30min
                                  used: false

4. Parent shows code on screen
   (or reads it aloud to child)

                                                          5. Child installs app,
                                                             selects "Enroll as Child"
                                                             enters code "A3K9M2X7"
                                                                   │
                                                                   ▼
                                                          6. App queries CloudKit
                                                             for invite with this code
                                                                   │
                                                                   ▼
                                                          7. Validate:
                                                             - code matches
                                                             - not expired
                                                             - not used
                                                                   │
                                                                   ▼
                                                          8. Generate DeviceID
                                                             Store in Keychain:
                                                               DeviceRole = .child
                                                               ChildEnrollmentState
                                                                   │
                                                                   ▼
                                                          9. Request FamilyControls
                                                             .individual authorization
                                                             (parent is physically present)
                                                                   │
                                                                   ▼
                                                          10. Create BBChildDevice
                                                              record in CloudKit
                                                                   │
                                                                   ▼
                                                          11. Mark BBEnrollmentInvite
                                  ◀───────────────────────    used = true
                                                              usedByDeviceID = ...

12. Parent sees new device
    appear in dashboard
```

### 9.2 Code Generation

- 8 uppercase alphanumeric characters, excluding ambiguous chars (0/O, 1/I/L).
- Character set: `A B C D E F G H J K M N P Q R S T U V W X Y Z 2 3 4 5 6 7 8 9` (32 chars).
- 8 chars from 32 = 32^8 ≈ 1.1 trillion combinations.
- Codes expire after 30 minutes.
- Codes are single-use.

### 9.3 Re-enrollment

If a child device needs to be replaced:
1. Parent deletes old device from dashboard (or marks it as replaced).
2. Parent generates a new enrollment code for the same child profile.
3. New device enrolls using the new code.
4. Old device, if still functional, shows "device unenrolled" state.

### 9.4 Parent PIN Distribution to Child Devices

During enrollment, the parent's PIN hash is synced to the child device via App Group storage (not CloudKit — PIN hash stays local). The parent enters their PIN on the child device during enrollment setup, and the app stores the bcrypt hash locally in the child device's Keychain. This enables offline local parent unlock.

If the parent changes their PIN, the new hash must be distributed. Options:
- **Option A:** Sync PIN hash via CloudKit (encrypted). Child devices fetch and update.
- **Option B:** Parent must physically re-enter PIN on each child device.

**Recommendation:** Option A with an additional layer: the PIN hash is encrypted with a key derived from the family ID before being stored in CloudKit. This way the public database doesn't expose the raw hash.

---

## 10. Command Architecture

### 10.1 Command Lifecycle

```
┌──────────┐     ┌───────────┐     ┌───────────┐     ┌─────────┐
│ pending  │────▶│ delivered │────▶│  applied  │     │ expired │
└──────────┘     └───────────┘     └───────────┘     └─────────┘
      │                │                                   ▲
      │                └──────────▶┌──────────┐            │
      │                            │  failed  │            │
      │                            └──────────┘            │
      └────────────────────────────────────────────────────┘
                   (if expiresAt < now)
```

Status transitions are monotonic — a command never goes backward.

### 10.2 Command Processing on Child Device

```swift
// CommandProcessor — pseudocode logic

func processIncomingCommands() async throws {
    let deviceID = enrollmentState.deviceID
    let childID = enrollmentState.childProfileID
    let familyID = enrollmentState.familyID

    // Fetch commands targeting: this device, this child, or all devices
    let commands = try await cloudKit.fetchPendingCommands(
        deviceID: deviceID,
        childProfileID: childID,
        familyID: familyID
    )

    for command in commands.sorted(by: { $0.issuedAt < $1.issuedAt }) {
        // Skip expired commands
        if let exp = command.expiresAt, exp < Date() {
            try await cloudKit.saveReceipt(.init(
                commandID: command.id, deviceID: deviceID,
                familyID: familyID, status: .expired
            ))
            continue
        }

        // Apply command
        let receipt = try await applyCommand(command)
        try await cloudKit.saveReceipt(receipt)
    }
}

func applyCommand(_ command: RemoteCommand) async throws -> CommandReceipt {
    switch command.action {
    case .setMode(let mode):
        // Update local policy, resolve effective policy, apply enforcement
        ...
    case .temporaryUnlock(let duration):
        // Set temp unlock, schedule expiry
        ...
    case .updatePolicy(let policy):
        // Replace local policy wholesale
        ...
    case .requestHeartbeat:
        // Send immediate heartbeat
        ...
    case .unenroll:
        // Clear enforcement, clear Keychain, reset to unconfigured
        ...
    }
}
```

### 10.3 Command Targeting Resolution

When a command targets a **child profile**, every device enrolled under that profile must independently fetch and apply the command. Each device produces its own `CommandReceipt`. The parent dashboard aggregates receipts to show per-device status.

When a command targets **all devices**, every device in the family fetches and applies it. Same receipt pattern.

### 10.4 Command Expiry

Commands without an explicit `expiresAt` default to 24 hours. This prevents stale commands from being applied if a device comes online days later with an outdated queue.

---

## 11. Policy Engine Architecture

### 11.1 Policy Resolution Priority

```
(highest priority)

1. Temporary Unlock
   └── If active and not expired → resolvedMode = .unlocked

2. Schedule Override
   └── If a schedule is active at current time → resolvedMode = schedule.mode

3. Base Policy Mode
   └── The mode set by the parent (default fallback)

(lowest priority)
```

Within any resolved mode, `alwaysAllowedApps` from the child profile are merged in as exceptions.

### 11.2 Mode Enforcement Details

| Mode            | ManagedSettings Behavior                                    |
|-----------------|-------------------------------------------------------------|
| `unlocked`      | Clear all shield settings. No restrictions.                 |
| `dailyMode`     | `store.shield.applicationCategories = .all(except: allowed)`. Allowed = always-allowed + daily-allowed list. |
| `fullLockdown`  | `store.shield.applicationCategories = .all()`. Only system-unblockable apps (Phone, Settings) remain usable. |
| `essentialOnly`  | `store.shield.applicationCategories = .all(except: essentialCategories)`. Essential = a curated category/app set. |

### 11.3 Named ManagedSettings Stores

ManagedSettings supports multiple named stores that stack. We use:

| Store Name      | Purpose                                                    |
|-----------------|-------------------------------------------------------------|
| `"base"`        | The primary enforcement store — set by mode                 |
| `"schedule"`    | Schedule-based overrides — set by DeviceActivityMonitor ext |
| `"tempUnlock"`  | Temporary unlock — clears restrictions for a duration       |

When a temporary unlock is active, the `"tempUnlock"` store clears restrictions. When it expires, the store is cleared and the `"base"` store's restrictions take effect again.

### 11.4 Essential Apps List

The "Essential Only" mode allows a narrow set. These are defined in `BigBrotherCore/Constants/Defaults.swift`:

```swift
// Defaults.swift

struct EssentialApps {
    /// Activity category tokens for essential categories.
    /// On-device, the app resolves these to actual ActivityCategoryTokens.
    static let categoryNames: Set<String> = [
        "utilities",      // Clock, Calculator, Contacts
        "communication",  // Messages, FaceTime
    ]

    /// Bundle IDs for reference (tokens are device-local, but bundle IDs
    /// help document intent and support capability warnings).
    static let referenceBundleIDs: Set<String> = [
        "com.apple.MobileSMS",     // Messages
        "com.apple.Maps",          // Maps
        "com.apple.mobilephone",   // Phone
        "com.apple.facetime",      // FaceTime
        "com.apple.findmy",        // Find My
        "com.apple.camera",        // Camera
        "com.apple.mobiletimer",   // Clock
        "com.apple.MobileAddressBook", // Contacts
    ]
}
```

**Capability warning:** Some system apps (Phone, Messages) cannot be blocked by ManagedSettings regardless. The policy engine should note this as a capability rather than an error — "Essential Only" mode is best-effort, and the fact that some apps are unblockable is a feature in this mode.

### 11.5 Always Allowed Apps

Per-child "Always Allowed" apps are selected using `FamilyActivityPicker` on the child device. The parent must be physically present and authenticated.

Flow:
1. Parent authenticates on child device (local PIN).
2. App shows `FamilyActivityPicker`.
3. Selected `ApplicationToken`s are serialized and stored:
   - Locally in App Group (for extensions)
   - In CloudKit `BBChildProfile.alwaysAllowedTokensData` (backup)
4. PolicyResolver includes these tokens as exceptions in all non-unlocked modes.

---

## 12. Reliability Architecture

### 12.1 Heartbeat System

**Child device sends a heartbeat every 5 minutes** while the app is in the foreground or during background fetch.

Heartbeat contains:
- Current mode
- Policy version
- FamilyControls authorization status
- Battery level
- Timestamp

**Parent dashboard** shows device status:
- Green: heartbeat within last 10 minutes
- Yellow: heartbeat 10–30 minutes ago
- Red: no heartbeat for 30+ minutes
- Gray: never connected

### 12.2 Background Execution Strategy

| Mechanism                        | Used For                                    |
|----------------------------------|---------------------------------------------|
| `BGAppRefreshTask`               | Periodic command polling + heartbeat         |
| `BGProcessingTask`               | Event log sync, stale data cleanup           |
| Silent push (CKSubscription)     | Near-real-time command delivery              |
| `DeviceActivityMonitor` extension | Schedule-based enforcement (always runs)    |

The `DeviceActivityMonitor` extension is the most reliable enforcement mechanism because the system guarantees it runs when schedules start/end, regardless of whether the main app is running.

### 12.3 Policy State Mirroring

```
┌──────────────────────────────────────────────────────────────────┐
│                     App Group Storage                             │
│                                                                  │
│  policy_snapshot.json                                            │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ PolicySnapshot                                           │    │
│  │   effectivePolicy: EffectivePolicy                       │    │
│  │   childProfile: ChildProfile?                            │    │
│  │   writtenAt: Date                                        │    │
│  │   writerVersion: Int                                     │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  shield_config.json                                              │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ ShieldConfig                                             │    │
│  │   title: String                                          │    │
│  │   message: String                                        │    │
│  │   showRequestButton: Bool                                │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  event_log_queue.json                                            │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ [EventLogEntry]  — append-only, cleared after sync       │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Write pattern:** Atomic write via temp file + rename. This ensures extensions never read a half-written file.

**Readers:** Main app, DeviceActivityMonitor, ShieldConfiguration, ShieldAction.

**Writers:** Main app only (for policy_snapshot and shield_config). Extensions may append to event_log_queue.

### 12.4 Restoration After Reboot / App Relaunch

1. **On app launch (child device):**
   - Read `DeviceRole` from Keychain → route to child mode.
   - Read `PolicySnapshot` from App Group.
   - Verify `ManagedSettingsStore` matches snapshot. If not, reapply.
   - Start heartbeat.
   - Process any pending commands.

2. **On reboot:**
   - `DeviceActivityMonitor` schedules persist across reboots (system-managed).
   - When a schedule fires, the extension reads App Group policy and applies enforcement.
   - The main app may not launch until the user opens it, but enforcement is maintained by the extension and the persisted ManagedSettingsStore state.

3. **ManagedSettingsStore persistence:**
   - ManagedSettingsStore writes persist across app launches and reboots. Once a restriction is set, it remains until explicitly cleared by the app or extension. This is a key reliability property.

### 12.5 Policy Reconciliation

On child device, reconciliation runs:
- On every app launch
- After every command application
- On background fetch
- When DeviceActivityMonitor fires

Reconciliation:
1. Read current PolicySnapshot from App Group.
2. Read current ManagedSettingsStore state.
3. If mismatched, reapply enforcement from snapshot.
4. Log reconciliation event.

### 12.6 Stale/Offline Device Handling

- Parent dashboard shows time since last heartbeat.
- If a device is offline for 1+ hours, the parent sees a warning.
- Commands to offline devices remain in `.pending` status.
- When the device comes online, it fetches and applies pending commands in chronological order.
- Commands older than 24 hours auto-expire.

---

## 13. Security Architecture

### 13.1 Secrets Storage Map

| Secret / Sensitive Data          | Storage Location          | Access                                        |
|----------------------------------|---------------------------|-----------------------------------------------|
| `DeviceRole`                     | Keychain                  | App + Monitor extension (via access group)     |
| `ChildEnrollmentState`           | Keychain                  | App + Monitor extension                        |
| `ParentState`                    | Keychain                  | App only                                       |
| `parentPINHash` (bcrypt)         | Keychain                  | App + Monitor extension                        |
| `parentPINSalt`                  | Keychain                  | App + Monitor extension                        |
| `familyID`                       | Keychain + App Group      | All targets                                    |
| `PolicySnapshot`                 | App Group (JSON)          | All targets                                    |
| `ShieldConfig`                   | App Group (JSON)          | Shield extension                               |
| `EventLogQueue`                  | App Group (JSON)          | All targets                                    |
| App selection tokens             | App Group (Data)          | App + extensions                               |

### 13.2 PIN Security

- PIN is 4–8 digits (configurable, recommend 6).
- Stored as bcrypt hash with random salt, cost factor 10.
- Validated locally — no network required.
- Failed attempt counter stored in App Group. After 5 consecutive failures, lock out for 5 minutes.
- Lockout state synced as an event log entry.

### 13.3 Local Parent Unlock on Child Device

```
Child Device
──────────────

ChildHomeView
    │
    └── "Parent Unlock" button
           │
           ▼
    LocalUnlockView
           │
           ├── Parent enters PIN
           │
           ▼
    PINHasher.verify(enteredPIN, storedHash)
           │
           ├── FAIL → increment failure counter, show error
           │
           └── SUCCESS
                  │
                  ▼
           1. Set temporaryUnlockUntil = now + 30 min (configurable)
           2. Write updated PolicySnapshot to App Group
           3. EnforcementService.clearAllRestrictions()
           4. EventLogger.log(.localPINUnlock, details: "30 min unlock")
           5. Show "Unlocked until HH:MM" on ChildHomeView
           6. Schedule re-lock (via local timer + DeviceActivitySchedule)
                  │
                  ▼
           When timer expires:
           1. PolicyResolver re-resolves without temp unlock
           2. Write new PolicySnapshot
           3. EnforcementService.apply(newPolicy)
           4. EventLogger.log(.temporaryUnlockExpired)
```

**Critical:** Local unlock does NOT change `DeviceRole`, does NOT show `ParentDashboardView`, and does NOT allow access to parent admin functions. It only suspends enforcement for a set duration.

### 13.4 Anti-Tampering Considerations

| Threat                                  | Mitigation                                              |
|-----------------------------------------|---------------------------------------------------------|
| Child deletes and reinstalls app        | ManagedSettings restrictions may persist (system-level). Parent is alerted by missing heartbeat. Keychain enrollment state survives reinstall on same device (unless Keychain is cleared). |
| Child revokes FamilyControls auth       | App detects `AuthorizationCenter.shared.authorizationStatus` change, logs event, sends alert heartbeat. |
| Child force-quits app                   | DeviceActivityMonitor extension runs independently. ManagedSettingsStore state persists. |
| Child resets device                     | Parent sees device go offline. Device must re-enroll. |
| Child finds enrollment code for another child | Codes are single-use and expire in 30 min. |
| Brute-force PIN guessing               | 5-attempt lockout with 5-minute cooldown. |

### 13.5 CloudKit Security

- `familyID` is a 128-bit UUID — infeasible to guess.
- No sensitive data (PINs, auth tokens) is stored in CloudKit.
- PIN hash is synced encrypted: encrypted with a key derived from `familyID` using HKDF-SHA256.
- CloudKit records use server-side change tokens for conflict detection.

---

## 14. Extension Responsibilities

### 14.1 BigBrotherMonitor (DeviceActivityMonitor)

**Type:** `DeviceActivityMonitor` subclass.

**Responsibility:** Responds to schedule events (interval start/end) by reading the policy snapshot from App Group storage and applying the appropriate ManagedSettings restrictions.

| Aspect       | Detail                                                         |
|--------------|----------------------------------------------------------------|
| **Reads**    | `PolicySnapshot` from App Group, `ChildEnrollmentState` from Keychain |
| **Writes**   | `ManagedSettingsStore` (named: `"schedule"`), `EventLogQueue` in App Group |
| **Cannot do**| Network calls, UI, long-running tasks                          |
| **Triggered**| By system when a registered `DeviceActivitySchedule` starts or ends |

```swift
// BigBrotherMonitorExtension.swift — skeleton

import DeviceActivity
import ManagedSettings
import BigBrotherCore

class BigBrotherMonitorExtension: DeviceActivityMonitor {
    let storage = AppGroupStorage()
    let store = ManagedSettingsStore(named: .init("schedule"))

    override func intervalDidStart(for activity: DeviceActivityName) {
        guard let snapshot = storage.readPolicySnapshot() else { return }
        applyShielding(from: snapshot.effectivePolicy)
        storage.appendEventLog(.init(/* scheduleTriggered */))
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        store.clearAllSettings()
        storage.appendEventLog(.init(/* scheduleEnded */))
    }

    private func applyShielding(from policy: EffectivePolicy) {
        // Decode token data, apply to store.shield.applications / categories
    }
}
```

### 14.2 BigBrotherShield (ShieldConfigurationDataSource)

**Type:** `ShieldConfigurationDataSource` subclass.

**Responsibility:** Provides the custom UI shown when a blocked app is launched.

| Aspect       | Detail                                                         |
|--------------|----------------------------------------------------------------|
| **Reads**    | `ShieldConfig` from App Group                                  |
| **Writes**   | Nothing                                                        |
| **Cannot do**| Network, complex logic, heavy assets                           |
| **Triggered**| By system when user taps a shielded app icon                   |

The shield shows:
- "This app is restricted"
- Current mode name (e.g., "Daily Mode")
- Optionally: time until next schedule change

```swift
// BigBrotherShieldExtension.swift — skeleton

import ManagedSettingsUI
import BigBrotherCore

class BigBrotherShieldExtension: ShieldConfigurationDataSource {
    let storage = AppGroupStorage()

    override func configuration(
        shielding application: Application
    ) -> ShieldConfiguration {
        let config = storage.readShieldConfiguration()
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(
                text: config?.title ?? "App Restricted",
                color: .white
            ),
            subtitle: ShieldConfiguration.Label(
                text: config?.message ?? "Ask a parent to unlock.",
                color: .secondary
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "OK",
                color: .white
            ),
            primaryButtonBackgroundColor: .systemBlue
        )
    }
}
```

### 14.3 BigBrotherShieldAction (ShieldActionDelegate)

**Type:** `ShieldActionDelegate` subclass.

**Responsibility:** Handles button taps on the shield screen.

| Aspect       | Detail                                                         |
|--------------|----------------------------------------------------------------|
| **Reads**    | App Group state                                                |
| **Writes**   | `EventLogQueue` in App Group                                   |
| **Cannot do**| Network, present UI                                            |
| **Triggered**| By system when user taps a button on the shield                |

When the user taps the primary button ("OK"), the extension dismisses the shield. No further action needed for Phase 2. In future phases, a "Request Unlock" button could log a request event.

```swift
// BigBrotherShieldActionExtension.swift — skeleton

import ManagedSettings
import BigBrotherCore

class BigBrotherShieldActionExtension: ShieldActionDelegate {
    let storage = AppGroupStorage()

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            // Future: log unlock request
            storage.appendEventLog(.init(/* appLaunchBlocked request */))
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }
}
```

### 14.4 Main App (BigBrother)

The main app owns everything the extensions cannot do:

| Responsibility                        | Detail                                              |
|---------------------------------------|-----------------------------------------------------|
| CloudKit sync                         | All network operations                               |
| Command processing                    | Fetch, validate, apply commands                      |
| Policy resolution                     | Run PolicyResolver, write snapshot to App Group      |
| Enforcement (base + temp)             | Write to `ManagedSettingsStore(named: "base")`       |
| Schedule registration                 | Register `DeviceActivitySchedule` with the system    |
| Heartbeat                             | Periodic heartbeat to CloudKit                       |
| Event sync                            | Flush App Group event queue to CloudKit              |
| Authentication                        | Biometric + PIN for parent mode                      |
| Enrollment                            | Code generation, device registration                 |
| UI                                    | All SwiftUI views                                    |
| Always Allowed app selection          | Present `FamilyActivityPicker`                       |

---

## 15. Risks and Tricky Areas

### 15.1 High-Risk

| Risk | Detail | Mitigation |
|------|--------|------------|
| **FamilyControls `.individual` revocation** | A child can go to Settings → Screen Time and revoke the app's authorization. There is no API to prevent this. | Detect via `AuthorizationCenter.shared.authorizationStatus`. Log event. Alert parent via heartbeat. The app cannot re-authorize without user consent. This is an inherent platform limitation. |
| **ManagedSettings limitations** | Cannot block Phone, Messages, Settings, or certain system apps. Cannot block emergency calls. Cannot prevent app deletion. | Document limitations clearly. Use `CapabilityWarning` in EffectivePolicy. "Essential Only" mode is best-effort by design. |
| **App killed / not running** | If the main app is killed and no DeviceActivitySchedule is registered, enforcement depends solely on persisted ManagedSettingsStore state (which does persist). No new commands will be processed. | Always register a DeviceActivitySchedule even if no schedule is configured — use it as a "reconciliation heartbeat." Re-apply enforcement on every app launch. |
| **CloudKit public database exposure** | Any user of the app could theoretically query all records if they knew the record type names. | `familyID` UUIDs are unguessable. No secrets stored in CloudKit. For App Store release, migrate to private database with CKShare. |

### 15.2 Medium-Risk

| Risk | Detail | Mitigation |
|------|--------|------------|
| **Background execution limits** | iOS aggressively limits background execution time. `BGAppRefreshTask` is not guaranteed to run frequently. | Rely on `DeviceActivityMonitor` extension (system-guaranteed) for critical enforcement. Use CKSubscription silent push for near-real-time command delivery. Accept that heartbeat interval may be irregular. |
| **ApplicationToken locality** | Tokens are device-specific. A token from device A is meaningless on device B. "Always Allowed" app configuration must happen per-device. | Use `FamilyActivityPicker` on each child device. Store tokens locally. Sync only as backup blobs. Use category-level controls for remote management. |
| **PIN hash distribution** | If parent changes PIN, child devices need the new hash. | Sync encrypted PIN hash via CloudKit. Child devices fetch on next sync. During gap, old PIN still works on child device (acceptable). |
| **Shared Apple ID + CloudKit** | If child device shares parent's Apple ID, they share the same CloudKit container. The child could theoretically use a different app to read CloudKit records. | Records contain no secrets. `familyID` is the only sensitive-ish value, and the child already has it embedded. This is acceptable. |

### 15.3 Low-Risk (But Worth Noting)

| Risk | Detail |
|------|--------|
| **Clock manipulation** | A child could change the device clock to bypass schedule-based restrictions. DeviceActivityMonitor uses system monotonic time, so this is partially mitigated. |
| **VPN / DNS circumvention** | Out of scope — this app controls app access, not network content. |
| **Multiple parents** | Both parents can issue commands. Last-command-wins. No conflict resolution beyond this. Acceptable for a 2-parent family. |

---

## 16. Phase 2 Implementation Order

Phase 2 builds the working app incrementally. Each step produces a testable, runnable artifact.

### Step 1: Project Setup & Core Module
Create the Xcode project with all targets and entitlements. Implement `BigBrotherCore`:
- All model types
- `AppGroupStorage`
- `KeychainManager`
- `PINHasher`
- `PolicyResolver`
- `StorageKeys` and `AppConstants`
- Unit tests for `PolicyResolver` and `PINHasher`

**Files:**
```
BigBrotherCore/Package.swift
BigBrotherCore/Sources/BigBrotherCore/Models/*.swift  (all 12 model files)
BigBrotherCore/Sources/BigBrotherCore/Policy/PolicyResolver.swift
BigBrotherCore/Sources/BigBrotherCore/Policy/CapabilityReport.swift
BigBrotherCore/Sources/BigBrotherCore/Storage/SharedStorageProtocol.swift
BigBrotherCore/Sources/BigBrotherCore/Storage/AppGroupStorage.swift
BigBrotherCore/Sources/BigBrotherCore/Storage/PolicySnapshot.swift
BigBrotherCore/Sources/BigBrotherCore/Storage/StorageKeys.swift
BigBrotherCore/Sources/BigBrotherCore/Security/KeychainProtocol.swift
BigBrotherCore/Sources/BigBrotherCore/Security/KeychainManager.swift
BigBrotherCore/Sources/BigBrotherCore/Security/PINHasher.swift
BigBrotherCore/Sources/BigBrotherCore/Security/DeviceRole.swift
BigBrotherCore/Sources/BigBrotherCore/Constants/AppConstants.swift
BigBrotherCore/Sources/BigBrotherCore/Constants/Defaults.swift
BigBrotherCore/Tests/BigBrotherCoreTests/PolicyResolverTests.swift
BigBrotherCore/Tests/BigBrotherCoreTests/PINHasherTests.swift
BigBrotherCore/Tests/BigBrotherCoreTests/AppGroupStorageTests.swift
```

### Step 2: App Shell & Role Routing
Implement the app entry point, role detection, and onboarding flow:
- `BigBrotherApp.swift`
- `AppState.swift`
- `RootRouter.swift`
- `OnboardingView.swift`
- `ParentSetupView.swift` (PIN creation only)
- `ChildEnrollView.swift` (stub)
- `AuthService.swift` (biometric + PIN)
- `ParentGate.swift`

### Step 3: Parent Dashboard (Local Only)
Build the parent dashboard with local data. No CloudKit yet:
- `ParentDashboardView.swift`
- `ChildCardView.swift`
- `ChildDetailView.swift`
- Create child profiles and mock devices locally.

### Step 4: CloudKit Layer
Implement CloudKit sync:
- `CloudKitService.swift`
- `CKRecordMapping.swift`
- `SyncCoordinator.swift`
- Set up CloudKit schema in dashboard.
- Test read/write of child profiles and devices.

### Step 5: Enrollment Flow
Implement full enrollment:
- `EnrollmentService.swift`
- `CodeGenerator.swift`
- `EnrollDeviceView.swift`
- Test: parent generates code, child enrolls, device appears in dashboard.

### Step 6: FamilyControls & Enforcement
Implement the enforcement layer:
- `FamilyControlsManager.swift`
- `EnforcementService.swift`
- Request `.individual` authorization during enrollment.
- Apply mode changes via `ManagedSettingsStore`.
- Test: set mode to fullLockdown, verify apps are shielded.

### Step 7: Command System
Implement remote commands:
- `CommandProcessor.swift`
- CloudKit subscriptions for commands.
- Command receipt flow.
- Test: parent sends "lock" command, child device applies it.

### Step 8: Extensions
Implement all three extensions:
- `BigBrotherMonitorExtension.swift`
- `BigBrotherShieldExtension.swift`
- `BigBrotherShieldActionExtension.swift`
- Register DeviceActivitySchedule.
- Test: schedule-based mode change works even when main app is killed.

### Step 9: Local Parent Unlock
Implement:
- `LocalUnlockView.swift`
- PIN validation on child device.
- Temporary unlock with auto-re-lock.
- Event logging.

### Step 10: Heartbeat & Event Sync
Implement:
- `HeartbeatService.swift`
- `EventLogger.swift`
- Background fetch tasks.
- Parent dashboard shows device online status.

### Step 11: Schedules
Implement schedule creation, editing, and enforcement:
- `ScheduleManager.swift`
- `PolicyEditorView.swift` (schedule section)
- DeviceActivityMonitor integration.

### Step 12: Polish & Edge Cases
- Policy reconciliation on launch.
- Stale command cleanup.
- Capability warnings in UI.
- Error handling and retry logic.
- Parent settings (PIN change, etc.).

---

## Appendix A: Key Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Identity model | App-managed enrollment, not Apple ID | Family exceeds Family Sharing limits |
| CloudKit database | Public with familyID partition | Works across all Apple ID configurations |
| FamilyControls auth | `.individual` | No Family Sharing dependency |
| iOS target | 17.0+ | @Observable, mature Screen Time APIs |
| Shared module | Local Swift Package | Clean dependency graph, testable |
| PIN storage | bcrypt hash in Keychain | Secure, offline-capable |
| Policy snapshot | JSON in App Group | Atomic writes, readable by all extensions |
| Named ManagedSettings stores | base / schedule / tempUnlock | Clean separation of enforcement sources |
| Command delivery | CKSubscription + polling fallback | Near-real-time with reliability fallback |
| Extension communication | App Group files (no network in extensions) | Platform constraint |

## Appendix B: Entitlements Checklist

```xml
<!-- BigBrother.entitlements -->
<key>com.apple.developer.family-controls</key>
<true/>
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.bigbrother.shared</string>
</array>
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.bigbrother.app</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
<key>com.apple.developer.aps-environment</key>
<string>production</string>
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.bigbrother.shared</string>
</array>
```

```xml
<!-- BigBrotherMonitor.entitlements -->
<key>com.apple.developer.family-controls</key>
<true/>
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.bigbrother.shared</string>
</array>
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.bigbrother.shared</string>
</array>
```
