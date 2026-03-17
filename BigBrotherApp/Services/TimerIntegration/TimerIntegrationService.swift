import Foundation
import Observation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import BigBrotherCore

/// Connects to AllowanceTracker's Firestore to read/write penalty timers.
/// Only active when explicitly enabled in settings.
@Observable
final class TimerIntegrationService {

    // MARK: - Published State

    /// Per-kid timer state, keyed by AllowanceTracker Firestore kid ID.
    var kidTimers: [String: KidTimerState] = [:]

    /// Current Firebase auth state.
    var isSignedIn: Bool = false

    /// Error visible to the user.
    var errorMessage: String?

    /// Whether a sign-in is in progress.
    var isSigningIn: Bool = false

    // MARK: - Types

    struct KidTimerState {
        let firestoreKidID: String
        let name: String
        /// Hex color string from AllowanceTracker (e.g. "#0D9488").
        let avatarColor: String?
        /// Avatar image URL from AllowanceTracker, if set.
        let avatarUrl: String?
        /// Seconds banked (when stopped).
        let penaltySeconds: Int
        /// When the running timer expires (nil = stopped).
        let timerEndTime: Date?

        var isRunning: Bool { timerEndTime != nil }

        /// Remaining seconds. Falls back to banked penaltySeconds if timer expired.
        var remainingSeconds: Int {
            guard let end = timerEndTime else { return penaltySeconds }
            let remaining = Int(end.timeIntervalSinceNow)
            return remaining > 0 ? remaining : penaltySeconds
        }

        /// Whether the timer is actively counting down (not expired).
        var isActivelyRunning: Bool {
            guard let end = timerEndTime else { return false }
            return end.timeIntervalSinceNow > 0
        }

        /// Formatted display string.
        var displayString: String {
            let secs = isActivelyRunning ? remainingSeconds : penaltySeconds
            if secs <= 0 { return "" }
            let h = secs / 3600
            let m = (secs % 3600) / 60
            let s = secs % 60
            if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - Internal

    /// Called when timer data changes so the parent can relay to CloudKit.
    var onTimerDataChanged: (([String: KidTimerState]) -> Void)?

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var config: TimerIntegrationConfig

    init() {
        self.config = TimerIntegrationConfig.load()
        self.isSignedIn = Auth.auth().currentUser != nil

        // Start listening immediately if already signed in.
        if config.isEnabled && isSignedIn, let familyID = config.firebaseFamilyID {
            startListening(familyID: familyID)
        }

        // Also listen for auth state changes — Firebase restores sessions async,
        // so currentUser may be nil at init but available moments later.
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.isSignedIn = user != nil
            if user != nil && self.listener == nil {
                let cfg = TimerIntegrationConfig.load()
                if cfg.isEnabled, let familyID = cfg.firebaseFamilyID {
                    self.startListening(familyID: familyID)
                }
            }
        }
    }

    deinit {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
        listener?.remove()
    }

    // MARK: - Auth

    func signIn(email: String, password: String) async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await Auth.auth().signIn(withEmail: trimmedEmail, password: trimmedPassword)
            isSignedIn = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        isSignedIn = false
        stopListening()
        kidTimers.removeAll()
    }

    // MARK: - Discovery

    /// Discovers the family ID and kids from Firestore using the current Firebase user.
    func discoverFamily() async throws -> (familyID: String, kids: [(id: String, name: String)]) {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw TimerError.notSignedIn
        }

        let memberships = try await db.collection("familyMembers")
            .whereField("userId", isEqualTo: uid)
            .getDocuments()

        guard let member = memberships.documents.first,
              let familyID = member.data()["familyId"] as? String else {
            throw TimerError.noFamily
        }

        let kidDocs = try await db.collection("families").document(familyID)
            .collection("kids")
            .getDocuments()

        let kids = kidDocs.documents.map { doc in
            (id: doc.documentID, name: doc.data()["name"] as? String ?? "")
        }

        return (familyID, kids)
    }

    // MARK: - Listening

    func startListening(familyID: String) {
        stopListening()
        listener = db.collection("families").document(familyID)
            .collection("kids")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, let documents = snapshot?.documents else { return }

                var newTimers: [String: KidTimerState] = [:]
                for doc in documents {
                    let data = doc.data()
                    let kidID = doc.documentID
                    let name = data["name"] as? String ?? ""
                    let avatarColor = data["avatarColor"] as? String
                    let avatarUrl = data["avatarUrl"] as? String
                    let penaltySeconds = (data["penaltySeconds"] as? NSNumber)?.intValue ?? 0
                    let timerEndTime = (data["timerEndTime"] as? Timestamp)?.dateValue()

                    newTimers[kidID] = KidTimerState(
                        firestoreKidID: kidID,
                        name: name,
                        avatarColor: avatarColor,
                        avatarUrl: avatarUrl,
                        penaltySeconds: penaltySeconds,
                        timerEndTime: timerEndTime
                    )
                }
                self.kidTimers = newTimers
                self.onTimerDataChanged?(newTimers)
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Timer Operations

    func startTimer(familyID: String, kidID: String) async {
        let kidRef = db.collection("families").document(familyID)
            .collection("kids").document(kidID)

        do {
            let snapshot = try await kidRef.getDocument()
            guard let data = snapshot.data(),
                  let penaltySeconds = data["penaltySeconds"] as? Int,
                  penaltySeconds > 0,
                  data["timerEndTime"] == nil || data["timerEndTime"] is NSNull
            else { return }

            let timerEndTime = Date().addingTimeInterval(TimeInterval(penaltySeconds))
            try await kidRef.updateData([
                "timerEndTime": Timestamp(date: timerEndTime),
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopTimer(familyID: String, kidID: String) async {
        let kidRef = db.collection("families").document(familyID)
            .collection("kids").document(kidID)

        do {
            let snapshot = try await kidRef.getDocument()
            guard let data = snapshot.data(),
                  let timerEndTimestamp = data["timerEndTime"] as? Timestamp
            else { return }

            let remaining = max(0, Int(timerEndTimestamp.dateValue().timeIntervalSinceNow))
            try await kidRef.updateData([
                "timerEndTime": FieldValue.delete(),
                "penaltySeconds": remaining,
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addTime(familyID: String, kidID: String, minutes: Int) async {
        let kidRef = db.collection("families").document(familyID)
            .collection("kids").document(kidID)

        do {
            let snapshot = try await kidRef.getDocument()
            guard let data = snapshot.data() else { return }

            if let timerEndTimestamp = data["timerEndTime"] as? Timestamp {
                // Timer is running — extend timerEndTime
                let newEnd = timerEndTimestamp.dateValue().addingTimeInterval(TimeInterval(minutes * 60))
                try await kidRef.updateData([
                    "timerEndTime": Timestamp(date: newEnd),
                    "updatedAt": Timestamp(date: Date())
                ])
            } else {
                // Timer is stopped — add to penaltySeconds
                let current = data["penaltySeconds"] as? Int ?? 0
                let newSeconds = max(0, current + minutes * 60)
                try await kidRef.updateData([
                    "penaltySeconds": newSeconds,
                    "updatedAt": Timestamp(date: Date())
                ])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearTimer(familyID: String, kidID: String) async {
        let kidRef = db.collection("families").document(familyID)
            .collection("kids").document(kidID)

        do {
            try await kidRef.updateData([
                "timerEndTime": FieldValue.delete(),
                "penaltySeconds": 0,
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Returns the timer state for a Big.Brother child, using the kid mapping.
    func timerState(for childID: ChildProfileID, config: TimerIntegrationConfig) -> KidTimerState? {
        guard let mapping = config.kidMappings.first(where: { $0.childProfileID == childID }),
              let timer = kidTimers[mapping.firestoreKidID]
        else { return nil }
        return timer
    }

    enum TimerError: LocalizedError {
        case notSignedIn
        case noFamily

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in to Firebase."
            case .noFamily: return "No family found for this account."
            }
        }
    }
}
