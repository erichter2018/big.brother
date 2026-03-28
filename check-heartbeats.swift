#!/usr/bin/env swift
// check-heartbeats.swift — Query CloudKit for latest heartbeats and print build numbers.
// Usage: swift check-heartbeats.swift <expected_build>
// Output: one line per device: "<deviceID> <build> <seconds_ago>"
// Exit 0 if query succeeded (even if no heartbeats found).

import Foundation
import CloudKit

let containerID = "iCloud.fr.bigbrother.app"
let expectedBuild = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil

let container = CKContainer(identifier: containerID)
let db = container.publicCloudDatabase

let semaphore = DispatchSemaphore(value: 0)

// Query all BBHeartbeat records (one per device, updated in place).
let query = CKQuery(recordType: "BBHeartbeat", predicate: NSPredicate(value: true))
let operation = CKQueryOperation(query: query)
operation.resultsLimit = 50

var records: [CKRecord] = []

operation.recordMatchedBlock = { _, result in
    if case .success(let record) = result {
        records.append(record)
    }
}

operation.queryResultBlock = { result in
    switch result {
    case .success:
        let now = Date()
        for record in records {
            let deviceID = record["deviceID"] as? String ?? "unknown"
            let build = record["hbAppBuildNumber"] as? Int64 ?? 0
            let timestamp = record["timestamp"] as? Date ?? Date.distantPast
            let secondsAgo = Int(now.timeIntervalSince(timestamp))
            print("\(deviceID) \(build) \(secondsAgo)")
        }
    case .failure(let error):
        fputs("ERROR: \(error.localizedDescription)\n", stderr)
    }
    semaphore.signal()
}

db.add(operation)

// Wait up to 30 seconds for the query.
let timeout = semaphore.wait(timeout: .now() + 30)
if timeout == .timedOut {
    fputs("ERROR: CloudKit query timed out\n", stderr)
    exit(1)
}
