# CloudKit Container Setup

## Container

**Identifier:** `iCloud.com.bigbrother.app`
**Database:** Public

### Why Public Database?

This app uses the public database because:
- Child devices may not be signed in to the same iCloud account as the parent
- Some child devices share a parent's Apple ID (family of 8, Apple limits)
- Public database allows any signed-in iCloud account to read/write records
- Security is enforced via familyID UUID partition key (unguessable)

### Authentication Model

All iCloud-signed-in devices can access the public database. No private database or iCloud sharing is needed. The familyID acts as a secret partition key:
- Parent generates a random UUID familyID during setup
- Child devices receive it during enrollment (via enrollment code → CloudKit lookup)
- All queries filter by familyID, scoping data to this family

## Record Types

Create these record types in the CloudKit Dashboard at https://icloud.developer.apple.com.

### BBChildProfile
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| profileID | String | YES | - |
| name | String | - | YES |
| avatarName | String | - | - |
| alwaysAllowedCategoriesJSON | String | - | - |
| createdAt | Date/Time | - | YES |
| updatedAt | Date/Time | - | YES |

### BBChildDevice
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| deviceID | String | YES | - |
| profileID | String | YES | - |
| displayName | String | - | - |
| modelIdentifier | String | - | - |
| osVersion | String | - | - |
| enrolledAt | Date/Time | - | YES |
| familyControlsOK | Int(64) | - | - |

### BBPolicy
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| deviceID | String | YES | - |
| mode | String | - | - |
| tempUnlockUntil | Date/Time | - | - |
| scheduleID | String | - | - |
| version | Int(64) | - | - |
| updatedAt | Date/Time | - | - |

### BBRemoteCommand
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| commandID | String | YES | - |
| targetType | String | YES | - |
| targetID | String | YES | - |
| actionJSON | String | - | - |
| issuedBy | String | - | - |
| issuedAt | Date/Time | - | YES |
| expiresAt | Date/Time | - | - |
| status | String | YES | - |

### BBCommandReceipt
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| commandID | String | YES | - |
| deviceID | String | YES | - |
| status | String | - | - |
| appliedAt | Date/Time | YES | YES |
| failureReason | String | - | - |

### BBHeartbeat
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| deviceID | String | YES | - |
| timestamp | Date/Time | - | YES |
| currentMode | String | - | - |
| policyVersion | Int(64) | - | - |
| fcAuthorized | Int(64) | - | - |
| batteryLevel | Double | - | - |
| isCharging | Int(64) | - | - |

### BBEventLog
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| eventID | String | YES | - |
| deviceID | String | YES | - |
| eventType | String | - | - |
| details | String | - | - |
| timestamp | Date/Time | YES | YES |

### BBEnrollmentInvite
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| code | String | YES | - |
| profileID | String | YES | - |
| createdAt | Date/Time | - | YES |
| expiresAt | Date/Time | - | - |
| used | Int(64) | - | - |
| usedByDeviceID | String | - | - |

### BBSchedule
| Field | Type | Queryable | Sortable |
|---|---|---|---|
| familyID | String | YES | - |
| profileID | String | YES | - |
| scheduleName | String | - | - |
| mode | String | - | - |
| daysOfWeekJSON | String | - | - |
| startHour | Int(64) | - | - |
| startMinute | Int(64) | - | - |
| endHour | Int(64) | - | - |
| endMinute | Int(64) | - | - |
| isActive | Int(64) | - | - |
| updatedAt | Date/Time | - | - |

## Index Setup

### Required Queryable Indexes
Every record type needs `familyID` as a queryable index (this is the primary partition key).

Additionally:
- **BBRemoteCommand:** `status`, `targetType`, `targetID` (for fetching pending commands)
- **BBEventLog:** `timestamp` (for date-range queries)
- **BBCommandReceipt:** `appliedAt` (for date-range queries)
- **BBEnrollmentInvite:** `code` (for code lookup during enrollment)

### How to Create Indexes
1. Go to CloudKit Dashboard
2. Select your container
3. Schema > Record Types > select record type
4. For each field marked "Queryable" above, check the Queryable checkbox
5. For each field marked "Sortable" above, check the Sortable checkbox
6. Save

## Subscriptions

Subscriptions are created programmatically by `CloudKitServiceImpl.setupSubscriptions()`.

### Child Device Subscription
- **Record Type:** BBRemoteCommand
- **Predicate:** familyID == {familyID} AND status == "pending"
- **Fires On:** Record creation
- **Notification:** Silent push (content-available)

When a parent sends a command, CloudKit creates a BBRemoteCommand record. The subscription fires a silent push to the child device, which wakes the app and triggers `BackgroundRefreshHandler` → `SyncCoordinator.performQuickSync()` → `CommandProcessor.processIncomingCommands()`.

### Parent Device Subscription
- **Record Type:** BBRemoteCommand
- **Predicate:** familyID == {familyID}
- **Fires On:** Record creation
- **Notification:** Silent push (content-available)

Parent devices subscribe to all command-related changes in their family to refresh the dashboard when receipts arrive.

## Environment Setup Steps

1. **Create Container:**
   - Go to CloudKit Dashboard
   - Create container `iCloud.com.bigbrother.app`

2. **Create Record Types:**
   - Create all 9 record types listed above
   - Add all fields with correct types

3. **Set Up Indexes:**
   - Add queryable/sortable indexes as specified

4. **Deploy Schema:**
   - Click "Deploy Schema to Production" when ready for production
   - Development environment is used automatically during development

5. **Verify in Xcode:**
   - Open your Xcode project
   - Go to Signing & Capabilities for the main app target
   - Verify the iCloud capability shows the correct container

## CloudKit Account Requirements

- **Parent device:** Must be signed in to any iCloud account
- **Child device:** Must be signed in to any iCloud account (can be the same or different from parent)
- **No Family Sharing required:** The app uses its own enrollment mechanism, not Apple's Family Sharing

## Graceful Degradation

When CloudKit is unavailable:
- `CloudKitEnvironment.checkAccountStatus()` detects the issue on launch
- `AppState.cloudKitStatusMessage` surfaces the error to the UI
- Child devices continue enforcing the last-known policy from the local snapshot
- Heartbeat and event sync fail silently and retry on next cycle
- Commands are not received until CloudKit becomes available

## Testing CloudKit

1. **Simulator:** CloudKit works in the Simulator if you're signed in to iCloud in System Preferences
2. **Device:** Must be signed in to iCloud on the device
3. **Dashboard:** Use CloudKit Dashboard to inspect records, verify schema, and debug queries
4. **Reset:** To reset the development environment, use "Reset Development Environment" in the CloudKit Dashboard
