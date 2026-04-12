#if canImport(FamilyControls)
import SwiftUI
import FamilyControls
import ManagedSettings
import CloudKit
import BigBrotherCore

/// Mode 2: Child-driven app selection for parent review.
///
/// Child selects all the apps they want. Each gets a 1-minute probe limit
/// for name harvesting. Child opens each app once so ShieldConfiguration
/// captures the real name. Parent reviews the list on their dashboard.
///
/// Can be triggered by:
/// - Parent command (requestChildAppPick)
/// - Child tapping "Request More Apps" on ChildHomeView
struct ChildAppPickView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var isSaving = false
    @State private var savedCount = 0
    @State private var skippedCount = 0
    @State private var showNaming = false
    @State private var cloudKitStatus = ""
    @State private var savedTokens: [ApplicationToken] = []
    @State private var savedReviews: [PendingAppReview] = []
    @State private var enteredNames: [UUID: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showNaming {
                    namingView
                } else {
                    pickerView
                }
            }
            .navigationTitle("Pick Your Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var pickerView: some View {
        VStack(spacing: 16) {
            Text("Select all the apps you want to use")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top)

            FamilyActivityPicker(selection: $selection)
                .onChange(of: selection) { _, newValue in
                    AppNameHarvester.harvest(from: newValue)
                }

            Button {
                processSelection()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.applicationTokens.isEmpty || isSaving)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    @ViewBuilder
    private var namingView: some View {
        VStack(spacing: 0) {
            Text("Name these apps")
                .font(.headline)
                .padding(.top)

            Text("Type the name you see next to each app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            if skippedCount > 0 {
                Text("\(skippedCount) already configured — skipped")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(Array(zip(savedTokens, savedReviews)), id: \.1.id) { token, review in
                    HStack(spacing: 12) {
                        // System-rendered app icon + name (Label resolves visually)
                        Label(token)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .frame(minWidth: 80, alignment: .leading)
                            .lineLimit(1)

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        TextField("Type name", text: nameBinding(for: review.id))
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .autocorrectionDisabled()
                    }
                }
            }
            .listStyle(.plain)

            if !cloudKitStatus.isEmpty {
                Text(cloudKitStatus)
                    .font(.caption2)
                    .foregroundStyle(cloudKitStatus.contains("ERROR") ? .red : .green)
                    .padding(.horizontal)
            }

            Button {
                saveNames()
            } label: {
                Text("Save")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Button("Skip — name later") { dismiss() }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
    }

    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { enteredNames[id] ?? "" },
            set: { enteredNames[id] = $0 }
        )
    }

    private func saveNames() {
        // Update reviews with entered names and re-push to CloudKit
        for review in savedReviews {
            if let name = enteredNames[review.id], !name.trimmingCharacters(in: .whitespaces).isEmpty {
                var updated = review
                updated.appName = name.trimmingCharacters(in: .whitespaces)
                updated.nameResolved = true
                updated.updatedAt = Date()
                // Update local file
                let storage = AppGroupStorage()
                if let data = storage.readRawData(forKey: "pending_review_local.json"),
                   var locals = try? JSONDecoder().decode([PendingAppReview].self, from: data),
                   let idx = locals.firstIndex(where: { $0.id == review.id }) {
                    locals[idx] = updated
                    if let encoded = try? JSONEncoder().encode(locals) {
                        try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
                    }
                }
                // Push updated review to CloudKit
                Task {
                    await pushReviewsToCloudKit([updated])
                }
            }
        }
        dismiss()
    }

    private func processSelection() {
        guard let enrollment = try? KeychainManager().get(
            ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
        ) else { return }

        isSaving = true
        let storage = AppGroupStorage()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Load existing blocked apps (FamilyActivitySelection) to merge with new picks.
        var pickerSelection: FamilyActivitySelection
        if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           let existing = try? decoder.decode(FamilyActivitySelection.self, from: data) {
            pickerSelection = existing
        } else {
            pickerSelection = FamilyActivitySelection()
        }

        // Check existing tokens to skip duplicates
        let existingTokens = pickerSelection.applicationTokens
        let allowedTokens: Set<ApplicationToken> = {
            guard let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                  let tokens = try? decoder.decode(Set<ApplicationToken>.self, from: data) else { return [] }
            return tokens
        }()

        var newReviews: [PendingAppReview] = []
        var newTokens: [ApplicationToken] = []
        var addedCount = 0
        var skipped = 0

        let nameCache = storage.readAllCachedAppNames()

        for token in selection.applicationTokens {
            // Skip if already in picker selection or always-allowed
            if existingTokens.contains(token) { skipped += 1; continue }
            if allowedTokens.contains(token) { skipped += 1; continue }

            guard let tokenData = try? encoder.encode(token) else { continue }
            let fingerprint = TokenFingerprint.fingerprint(for: tokenData)
            let tokenKey = tokenData.base64EncodedString()

            let name = nameCache[tokenKey] ?? "App \(addedCount + 1)"

            // Add to picker selection — enforcement will put it in shield.applications.
            pickerSelection.applicationTokens.insert(token)

            let review = PendingAppReview(
                familyID: enrollment.familyID,
                childProfileID: enrollment.childProfileID,
                deviceID: enrollment.deviceID,
                appFingerprint: fingerprint,
                appName: name,
                nameResolved: false
            )
            newReviews.append(review)
            newTokens.append(token)

            storage.cacheAppName(name, forTokenKey: tokenKey)

            addedCount += 1
        }

        // Save updated picker selection — enforcement reads this for shield.applications
        if let encoded = try? encoder.encode(pickerSelection) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.familyActivitySelection)
        }

        // Save reviews locally for ShieldConfiguration name resolution
        if !newReviews.isEmpty {
            var pending: [PendingAppReview] = {
                guard let data = storage.readRawData(forKey: "pending_review_local.json") else { return [] }
                return (try? JSONDecoder().decode([PendingAppReview].self, from: data)) ?? []
            }()
            pending.append(contentsOf: newReviews)
            if let encoded = try? JSONEncoder().encode(pending) {
                try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
            }
            // Also signal tunnel for redundant sync
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: "pendingReviewNeedsSync")
        }

        // Re-apply enforcement — new tokens will appear in shield.applications
        if let enforcement = appState.enforcement,
           let snapshot = appState.snapshotStore?.loadCurrentSnapshot() {
            try? enforcement.apply(snapshot.effectivePolicy)
        }

        savedCount = addedCount
        skippedCount = skipped
        savedTokens = newTokens
        savedReviews = newReviews
        isSaving = false
        showNaming = true

        // Push reviews to CloudKit directly from the main app — don't wait for tunnel.
        if !newReviews.isEmpty {
            Task {
                await pushReviewsToCloudKit(newReviews)
            }
        }
    }

    private func pushReviewsToCloudKit(_ reviews: [PendingAppReview]) async {
        await MainActor.run { cloudKitStatus = "Pushing \(reviews.count) to CloudKit..." }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        var records: [CKRecord] = []
        for review in reviews {
            let recordID = CKRecord.ID(recordName: "BBPendingAppReview_\(review.id.uuidString)")
            let record = CKRecord(recordType: "BBPendingAppReview", recordID: recordID)
            record["familyID"] = review.familyID.rawValue
            record["profileID"] = review.childProfileID.rawValue
            record["deviceID"] = review.deviceID.rawValue
            record["appFingerprint"] = review.appFingerprint
            record["appName"] = review.appName
            record["appBundleID"] = review.bundleID
            record["nameResolved"] = (review.nameResolved ? 1 : 0) as NSNumber
            record["createdAt"] = review.createdAt as NSDate
            record["updatedAt"] = review.updatedAt as NSDate
            records.append(record)
        }

        let op = CKModifyRecordsOperation(recordsToSave: records)
        op.savePolicy = .changedKeys
        op.isAtomic = false
        op.qualityOfService = .userInitiated

        var savedCount = 0
        var perRecordErrors: [String] = []

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.perRecordSaveBlock = { recordID, result in
                    switch result {
                    case .success: savedCount += 1
                    case .failure(let error): perRecordErrors.append("\(recordID.recordName): \(error.localizedDescription)")
                    }
                }
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                db.add(op)
            }
            let msg = "OK: \(savedCount)/\(reviews.count) saved to CloudKit"
                + (perRecordErrors.isEmpty ? "" : " | Errors: \(perRecordErrors.joined(separator: "; "))")
            await MainActor.run { cloudKitStatus = msg }
        } catch {
            await MainActor.run { cloudKitStatus = "ERROR: \(error.localizedDescription)" }
        }
    }
}
#endif
