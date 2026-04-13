import Foundation
import CloudKit
import CoreLocation
import SwiftUI
import Observation
import BigBrotherCore

@Observable
@MainActor
final class LiveLocationManager {
    private let deviceID: DeviceID

    private(set) var latestLocation: BBLiveLocation?
    private(set) var smoothCoordinate: CLLocationCoordinate2D?
    private(set) var trail: [CLLocationCoordinate2D] = []
    private(set) var speedMPH: Int?
    private(set) var isLive = false

    private var pollTimer: Timer?
    private static let maxTrailPoints = 60

    init(deviceID: DeviceID) {
        self.deviceID = deviceID
    }

    func start() {
        guard pollTimer == nil else { return }
        isLive = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
    }

    func stop() {
        isLive = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() async {
        guard isLive else { return }
        let recordName = "BBLiveLocation_\(deviceID.rawValue)"
        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        do {
            let record = try await db.record(for: CKRecord.ID(recordName: recordName))
            guard let lat = record["latitude"] as? Double,
                  let lon = record["longitude"] as? Double,
                  let ts = record["timestamp"] as? Date else { return }

            let age = Date().timeIntervalSince(ts)
            guard age < 30 else {
                if isLive { isLive = false }
                return
            }

            let speed = record["speed"] as? Double
            let course = record["course"] as? Double
            let accuracy = record["accuracy"] as? Double ?? 0

            let loc = BBLiveLocation(
                id: deviceID,
                latitude: lat, longitude: lon,
                horizontalAccuracy: accuracy,
                timestamp: ts,
                speed: speed, course: course
            )

            if latestLocation?.timestamp != loc.timestamp {
                latestLocation = loc
                let newCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                withAnimation(.linear(duration: 2.5)) {
                    smoothCoordinate = newCoord
                }

                trail.append(newCoord)
                if trail.count > Self.maxTrailPoints {
                    trail.removeFirst(trail.count - Self.maxTrailPoints)
                }

                if let s = speed, s >= 0 {
                    speedMPH = Int(s * 2.237)
                }

                isLive = true
            }
        } catch {
            // Record doesn't exist yet or fetch failed — not an error for live tracking
        }
    }
}
