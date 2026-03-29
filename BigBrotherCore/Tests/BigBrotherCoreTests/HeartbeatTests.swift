import Testing
@testable import BigBrotherCore
import Foundation

@Suite("DeviceHeartbeat")
struct HeartbeatTests {

    let deviceID = DeviceID.generate()
    let familyID = FamilyID.generate()

    @Test("Heartbeat encodes and decodes correctly")
    func roundtrip() throws {
        let hb = DeviceHeartbeat(
            deviceID: deviceID,
            familyID: familyID,
            currentMode: .locked,
            policyVersion: 42,
            familyControlsAuthorized: true,
            batteryLevel: 0.75,
            isCharging: true
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(hb)
        let decoded = try decoder.decode(DeviceHeartbeat.self, from: data)

        #expect(decoded.deviceID == deviceID)
        #expect(decoded.familyID == familyID)
        #expect(decoded.currentMode == .locked)
        #expect(decoded.policyVersion == 42)
        #expect(decoded.familyControlsAuthorized == true)
        #expect(decoded.batteryLevel == 0.75)
        #expect(decoded.isCharging == true)
    }

    @Test("Heartbeat without optional fields")
    func withoutOptionals() throws {
        let hb = DeviceHeartbeat(
            deviceID: deviceID,
            familyID: familyID,
            currentMode: .unlocked,
            policyVersion: 1,
            familyControlsAuthorized: false
        )

        let data = try JSONEncoder().encode(hb)
        let decoded = try JSONDecoder().decode(DeviceHeartbeat.self, from: data)

        #expect(decoded.batteryLevel == nil)
        #expect(decoded.isCharging == nil)
    }

    @Test("ChildDevice online status from heartbeat")
    func onlineStatus() {
        var device = ChildDevice(
            id: deviceID,
            childProfileID: ChildProfileID.generate(),
            familyID: familyID,
            displayName: "Test iPad",
            modelIdentifier: "iPad14,1",
            osVersion: "17.0.0"
        )

        // No heartbeat = offline.
        #expect(!device.isOnline)

        // Recent heartbeat = online.
        device.lastHeartbeat = Date()
        #expect(device.isOnline)

        // Old heartbeat = offline.
        device.lastHeartbeat = Date().addingTimeInterval(-700)
        #expect(!device.isOnline)
    }
}
