# AllowanceTracker Timer Integration Guide

This document describes how to read, start, and stop AllowanceTracker timers from another app using direct Firestore access. No changes to AllowanceTracker are required.

---

## Prerequisites

1. **Same Firebase project** — Your other app must use the same Firebase project as AllowanceTracker. Add the appropriate config file:
   - **iOS:** Copy `GoogleService-Info.plist` from the AllowanceTracker Firebase project (download from Firebase Console > Project Settings)
   - **Android:** Download `google-services.json` from Firebase Console
   - **Web:** Use the Firebase config object from Firebase Console

2. **Firebase Auth** — The user must be authenticated. AllowanceTracker uses Firebase Auth. Your app can use any Firebase Auth method (email/password, anonymous, etc.) as long as the authenticated user has permission to access the family's data. Check your Firestore security rules (managed in Firebase Console) to confirm what's required.

3. **Known IDs** — You need the `familyId` and `kidId` to interact with timers. See "Discovering IDs" below.

---

## Firestore Document Structure

Timer state lives on each **kid document**:

```
families/{familyId}/kids/{kidId}
```

### Relevant Fields

| Field | Firestore Type | Swift Type | Description |
|-------|---------------|------------|-------------|
| `penaltySeconds` | `number` (integer) | `Int` | Banked timer seconds (when timer is stopped) |
| `timerEndTime` | `timestamp` or absent | `Date?` | When the running timer expires. Absent/null = timer is stopped |
| `name` | `string` | `String` | Kid's display name |
| `avatarColor` | `string` | `String` | Hex color string (e.g. `"#0D9488"`) |
| `updatedAt` | `timestamp` | `Date` | Last modification time |

### Full Kid Document Shape (for reference)

```json
{
  "name": "string",
  "avatarColor": "string (hex, e.g. #0D9488)",
  "avatarUrl": "string? (optional)",
  "dailyAllowance": "number (double)",
  "lastAllowanceAt": "timestamp?",
  "currentBalance": "number (double)",
  "penaltySeconds": "number (integer)",
  "timerEndTime": "timestamp? (null/absent when stopped)",
  "order": "number (integer)",
  "hasLoggedIn": "boolean?",
  "createdAt": "timestamp",
  "updatedAt": "timestamp"
}
```

---

## Timer State Machine

The timer has exactly two states:

### Stopped (`timerEndTime` is null/absent)
- `penaltySeconds` holds the total banked time in seconds
- If `penaltySeconds == 0`, there is no timer set

### Running (`timerEndTime` is a future timestamp)
- `timerEndTime` is the absolute UTC time when the timer expires
- Remaining time = `timerEndTime - now` (in seconds)
- `penaltySeconds` is stale while running (it holds the value from before the timer started)

### Timer Expired (`timerEndTime` is a past timestamp)
- The timer has completed but hasn't been cleaned up yet
- AllowanceTracker will handle cleanup when it next observes the state
- Your app should treat this as "timer finished" (remaining = 0)

---

## Operations

### 1. Read Timer State (Real-Time)

Set up a Firestore snapshot listener on the kid document. This gives you real-time updates whenever AllowanceTracker (or your app) changes the timer.

#### Swift (iOS)
```swift
import FirebaseFirestore

let db = Firestore.firestore()

// Listen to a single kid's document
let listener = db.collection("families").document(familyId)
    .collection("kids").document(kidId)
    .addSnapshotListener { snapshot, error in
        guard let data = snapshot?.data() else { return }

        let penaltySeconds = data["penaltySeconds"] as? Int ?? 0
        let timerEndTime = (data["timerEndTime"] as? Timestamp)?.dateValue()
        let kidName = data["name"] as? String ?? ""

        if let endTime = timerEndTime {
            // Timer is running
            let remaining = max(0, Int(endTime.timeIntervalSinceNow))
            print("\(kidName): timer running, \(remaining)s remaining")
        } else if penaltySeconds > 0 {
            // Timer is stopped with banked time
            print("\(kidName): \(penaltySeconds)s banked (not running)")
        } else {
            // No timer
            print("\(kidName): no timer set")
        }
    }

// To stop listening:
// listener.remove()
```

#### Listen to ALL kids in a family
```swift
let listener = db.collection("families").document(familyId)
    .collection("kids")
    .order(by: "order")
    .addSnapshotListener { snapshot, error in
        guard let documents = snapshot?.documents else { return }

        for doc in documents {
            let data = doc.data()
            let kidId = doc.documentID
            let name = data["name"] as? String ?? ""
            let penaltySeconds = data["penaltySeconds"] as? Int ?? 0
            let timerEndTime = (data["timerEndTime"] as? Timestamp)?.dateValue()

            // Process each kid's timer state...
        }
    }
```

#### Kotlin (Android)
```kotlin
val db = Firebase.firestore

db.collection("families").document(familyId)
    .collection("kids").document(kidId)
    .addSnapshotListener { snapshot, error ->
        val data = snapshot?.data ?: return@addSnapshotListener

        val penaltySeconds = (data["penaltySeconds"] as? Long)?.toInt() ?: 0
        val timerEndTime = (data["timerEndTime"] as? Timestamp)?.toDate()
        val kidName = data["name"] as? String ?: ""

        if (timerEndTime != null) {
            val remaining = maxOf(0, ((timerEndTime.time - System.currentTimeMillis()) / 1000).toInt())
            // Timer running, $remaining seconds left
        } else if (penaltySeconds > 0) {
            // Timer stopped, $penaltySeconds banked
        }
    }
```

#### JavaScript (Web)
```javascript
import { doc, onSnapshot } from "firebase/firestore";

const unsubscribe = onSnapshot(
  doc(db, "families", familyId, "kids", kidId),
  (snapshot) => {
    const data = snapshot.data();
    const penaltySeconds = data.penaltySeconds || 0;
    const timerEndTime = data.timerEndTime?.toDate();

    if (timerEndTime) {
      const remaining = Math.max(0, Math.floor((timerEndTime - Date.now()) / 1000));
      // Timer running
    } else if (penaltySeconds > 0) {
      // Timer stopped with banked time
    }
  }
);
```

---

### 2. Start a Timer

Starting a timer sets `timerEndTime` to `now + penaltySeconds`. This is a **two-step read-then-write** — you must first read the current `penaltySeconds` to know the duration.

#### Swift (iOS)
```swift
func startTimer(familyId: String, kidId: String) async throws {
    let kidRef = db.collection("families").document(familyId)
        .collection("kids").document(kidId)

    let snapshot = try await kidRef.getDocument()
    guard let data = snapshot.data(),
          let penaltySeconds = data["penaltySeconds"] as? Int,
          penaltySeconds > 0 else {
        return // No time banked, nothing to start
    }

    let timerEndTime = Date().addingTimeInterval(TimeInterval(penaltySeconds))

    try await kidRef.updateData([
        "timerEndTime": Timestamp(date: timerEndTime),
        "updatedAt": Timestamp(date: Date())
    ])
}
```

#### Kotlin (Android)
```kotlin
suspend fun startTimer(familyId: String, kidId: String) {
    val kidRef = db.collection("families").document(familyId)
        .collection("kids").document(kidId)

    val snapshot = kidRef.get().await()
    val penaltySeconds = snapshot.getLong("penaltySeconds")?.toInt() ?: return
    if (penaltySeconds <= 0) return

    val timerEndTime = Timestamp(Date(System.currentTimeMillis() + penaltySeconds * 1000L))

    kidRef.update(mapOf(
        "timerEndTime" to timerEndTime,
        "updatedAt" to Timestamp.now()
    )).await()
}
```

#### JavaScript (Web)
```javascript
async function startTimer(familyId, kidId) {
  const kidRef = doc(db, "families", familyId, "kids", kidId);
  const snapshot = await getDoc(kidRef);
  const penaltySeconds = snapshot.data()?.penaltySeconds || 0;

  if (penaltySeconds <= 0) return;

  const timerEndTime = new Date(Date.now() + penaltySeconds * 1000);

  await updateDoc(kidRef, {
    timerEndTime: Timestamp.fromDate(timerEndTime),
    updatedAt: Timestamp.now()
  });
}
```

---

### 3. Stop a Timer

Stopping a timer saves the remaining seconds back to `penaltySeconds` and removes `timerEndTime`.

#### Swift (iOS)
```swift
func stopTimer(familyId: String, kidId: String) async throws {
    let kidRef = db.collection("families").document(familyId)
        .collection("kids").document(kidId)

    let snapshot = try await kidRef.getDocument()
    guard let data = snapshot.data(),
          let timerEndTimestamp = data["timerEndTime"] as? Timestamp else {
        return // Timer isn't running
    }

    let timerEndTime = timerEndTimestamp.dateValue()
    let remainingSeconds = max(0, Int(timerEndTime.timeIntervalSinceNow))

    try await kidRef.updateData([
        "timerEndTime": FieldValue.delete(),
        "penaltySeconds": remainingSeconds,
        "updatedAt": Timestamp(date: Date())
    ])
}
```

**Important:** `timerEndTime` is removed using `FieldValue.delete()`, not set to `nil`/`null`. This removes the field from the document entirely, which is how AllowanceTracker checks for "timer not running" (`kid.timerEndTime == nil` after Codable decoding).

#### Kotlin (Android)
```kotlin
suspend fun stopTimer(familyId: String, kidId: String) {
    val kidRef = db.collection("families").document(familyId)
        .collection("kids").document(kidId)

    val snapshot = kidRef.get().await()
    val timerEndTime = snapshot.getTimestamp("timerEndTime") ?: return

    val remainingMs = timerEndTime.toDate().time - System.currentTimeMillis()
    val remainingSeconds = maxOf(0, (remainingMs / 1000).toInt())

    kidRef.update(mapOf(
        "timerEndTime" to FieldValue.delete(),
        "penaltySeconds" to remainingSeconds,
        "updatedAt" to Timestamp.now()
    )).await()
}
```

#### JavaScript (Web)
```javascript
async function stopTimer(familyId, kidId) {
  const kidRef = doc(db, "families", familyId, "kids", kidId);
  const snapshot = await getDoc(kidRef);
  const timerEndTime = snapshot.data()?.timerEndTime?.toDate();

  if (!timerEndTime) return;

  const remainingSeconds = Math.max(0, Math.floor((timerEndTime - Date.now()) / 1000));

  await updateDoc(kidRef, {
    timerEndTime: deleteField(),
    penaltySeconds: remainingSeconds,
    updatedAt: Timestamp.now()
  });
}
```

---

### 4. Add/Remove Time (While Stopped)

Adjust `penaltySeconds` directly. AllowanceTracker clamps to a minimum of 0.

#### Swift (iOS)
```swift
func addPenaltyMinutes(familyId: String, kidId: String, minutes: Int) async throws {
    let kidRef = db.collection("families").document(familyId)
        .collection("kids").document(kidId)

    let snapshot = try await kidRef.getDocument()
    guard let data = snapshot.data(),
          let currentSeconds = data["penaltySeconds"] as? Int else { return }

    let newSeconds = max(0, currentSeconds + minutes * 60)

    try await kidRef.updateData([
        "penaltySeconds": newSeconds,
        "updatedAt": Timestamp(date: Date())
    ])
}
```

### 5. Clear Timer Completely

Set `penaltySeconds` to 0 and delete `timerEndTime`:

```swift
func clearTimer(familyId: String, kidId: String) async throws {
    let kidRef = db.collection("families").document(familyId)
        .collection("kids").document(kidId)

    try await kidRef.updateData([
        "timerEndTime": FieldValue.delete(),
        "penaltySeconds": 0,
        "updatedAt": Timestamp(date: Date())
    ])
}
```

---

## Displaying a Countdown

To show a live countdown in your UI, use a 1-second timer and compute remaining time from `timerEndTime`:

#### Swift (iOS / SwiftUI)
```swift
struct TimerCountdownView: View {
    let timerEndTime: Date

    @State private var remaining: Int = 0
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatDuration(remaining))
            .onAppear { updateRemaining() }
            .onReceive(tick) { _ in updateRemaining() }
    }

    private func updateRemaining() {
        remaining = max(0, Int(timerEndTime.timeIntervalSinceNow))
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)h \(m)m"
        }
        let m = seconds / 60
        let s = seconds % 60
        return "\(m)m \(s)s"
    }
}
```

---

## Discovering IDs

Your app needs `familyId` and `kidId`. Here's how to get them:

### If the user authenticates with Firebase Auth (same account)

```swift
// Get the authenticated user's family
let userId = Auth.auth().currentUser!.uid

let memberships = try await db.collection("familyMembers")
    .whereField("userId", isEqualTo: userId)
    .getDocuments()

guard let member = memberships.documents.first else { return }
let familyId = member.data()["familyId"] as! String

// Now get all kids
let kids = try await db.collection("families").document(familyId)
    .collection("kids")
    .order(by: "order")
    .getDocuments()

for doc in kids.documents {
    let kidId = doc.documentID
    let name = doc.data()["name"] as? String ?? ""
    // Store these for timer operations
}
```

### familyMembers Collection Structure

The `familyMembers` collection (top-level, not nested) maps users to families:

```json
{
  "userId": "firebase-auth-uid",
  "familyId": "the-family-document-id",
  "role": "owner | parent | kid | kitchen",
  "kidId": "linked-kid-id (only if role=kid)",
  "createdAt": "timestamp",
  "updatedAt": "timestamp"
}
```

---

## Real-Time Sync Behavior

When your app writes to Firestore, AllowanceTracker will pick up the change automatically through its own snapshot listener. Specifically:

- **Timer started from your app** — AllowanceTracker's `DashboardViewModel` listener fires, UI updates to show the running timer. However, **Live Activities** (Lock Screen/Dynamic Island) and **local notifications** will only be triggered if AllowanceTracker is running or backgrounded, because those are scheduled by AllowanceTracker's in-process `LiveActivityManager` and `NotificationService`.

- **Timer stopped from your app** — AllowanceTracker sees `timerEndTime` become nil, updates UI accordingly, and cancels any pending notifications for that kid.

- **Time added/removed from your app** — AllowanceTracker's listener updates the displayed `penaltySeconds` in real-time.

---

## Edge Cases to Handle

1. **Race conditions** — If both apps try to start/stop simultaneously, the last write wins. For critical cases, use a Firestore transaction:
   ```swift
   try await db.runTransaction { transaction, errorPointer in
       let snapshot = try transaction.getDocument(kidRef)
       // Check current state, then write
       return nil
   }
   ```

2. **Timer already running** — Before starting, check that `timerEndTime` is nil. AllowanceTracker's `startTimer` silently returns if `penaltySeconds <= 0`.

3. **Clock skew** — `timerEndTime` is an absolute timestamp. If the writing device's clock is off, the timer duration will be wrong on other devices. Firestore `Timestamp` uses the client's clock for `Date()` — consider using `FieldValue.serverTimestamp()` for `updatedAt` but calculate `timerEndTime` locally (since it needs to be `now + penaltySeconds`).

4. **Timer expiration** — AllowanceTracker does NOT auto-clear expired timers in Firestore. It just shows 0:00 in the UI. The `timerEndTime` field may persist as a past date until someone manually clears it or the next interaction occurs.

---

## Firestore Security Rules

Your security rules (managed in Firebase Console > Firestore > Rules) must allow the authenticated user in your other app to read/write the kid documents. The exact rules depend on how you've configured them. Typical patterns:

- **Same user auth** — If your other app authenticates as the same Firebase user (parent/owner), existing rules should work.
- **Service account** — If your other app runs server-side with admin credentials, it bypasses rules entirely.
- **New auth method** — You may need to add a rule allowing the new app's users to access `families/{familyId}/kids/{kidId}`.

---

## Quick Reference

| Operation | Fields to Write | Guard Condition |
|-----------|----------------|-----------------|
| **Read state** | (listen only) | — |
| **Start timer** | `timerEndTime = now + penaltySeconds` | `penaltySeconds > 0` and `timerEndTime == nil` |
| **Stop timer** | `timerEndTime = DELETE`, `penaltySeconds = remaining` | `timerEndTime != nil` |
| **Add time (stopped)** | `penaltySeconds = max(0, current + delta)` | `timerEndTime == nil` |
| **Add time (running)** | `timerEndTime = current + delta` | `timerEndTime != nil` |
| **Clear timer** | `timerEndTime = DELETE`, `penaltySeconds = 0` | — |

All writes should also set `updatedAt = Timestamp(date: Date())`.

Document path: `families/{familyId}/kids/{kidId}`
