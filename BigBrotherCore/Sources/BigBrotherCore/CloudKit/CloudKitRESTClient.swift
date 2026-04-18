import Foundation

/// Shared CloudKit Web Services REST client, usable from both the main app
/// and the Packet Tunnel extension (which has no CKContainer access).
/// All methods are static — no instance state. Thread safety comes from
/// URLSession (thread-safe) and atomic property access via NSLock.
public enum CloudKitRESTClient {

    // MARK: - Configuration

    public static let apiToken = "1a091d3460a9c1b488dd4259ae2f5c7bd9200ef9dd311a42c1b447da992766b7"

    #if DEBUG
    private static let environment = "development"
    #else
    private static let environment = "production"
    #endif

    private static let baseURL = "https://api.apple-cloudkit.com/database/1/\(AppConstants.cloudKitContainerIdentifier)/\(environment)/public"

    private static let maxPages = 10
    private static let pageSize = 200

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Auth State

    private static let lock = NSLock()
    private static var _webAuthToken: String?
    private static var _restDisabled = false

    public static var webAuthToken: String? {
        get { lock.withLock { _webAuthToken } }
        set { lock.withLock { _webAuthToken = newValue } }
    }

    public static var restDisabledDueToAuthError: Bool {
        get { lock.withLock { _restDisabled } }
        set { lock.withLock { _restDisabled = newValue } }
    }

    public static func tripAuthCircuitBreaker() {
        restDisabledDueToAuthError = true
        BBLog("[CloudKitREST] Circuit breaker tripped — REST writes disabled for this session")
    }

    // MARK: - Types

    public struct RESTRecord {
        public let recordName: String
        public let recordType: String
        public let fields: [String: [String: Any]]

        public func string(_ key: String) -> String? {
            fields[key]?["value"] as? String
        }

        public func int64(_ key: String) -> Int64? {
            if let n = fields[key]?["value"] as? NSNumber { return n.int64Value }
            return nil
        }

        public func int(_ key: String) -> Int? {
            if let n = fields[key]?["value"] as? NSNumber { return n.intValue }
            return nil
        }

        public func double(_ key: String) -> Double? {
            if let n = fields[key]?["value"] as? NSNumber { return n.doubleValue }
            return nil
        }

        public func bool(_ key: String) -> Bool? {
            if let n = fields[key]?["value"] as? NSNumber { return n.intValue != 0 }
            return nil
        }

        public func date(_ key: String) -> Date? {
            if let ms = fields[key]?["value"] as? NSNumber {
                return Date(timeIntervalSince1970: ms.doubleValue / 1000.0)
            }
            return nil
        }

        public func stringList(_ key: String) -> [String]? {
            if let arr = fields[key]?["value"] as? [String] { return arr }
            return nil
        }
    }

    public enum RESTError: Error {
        case requestFailed(Error)
        case badResponse(Int)
        case decodingFailed
        case recordError(serverErrorCode: String, reason: String)

        public var isAuthError: Bool {
            switch self {
            case .badResponse(let code):
                return code == 401 || code == 421
            case .recordError(let serverErrorCode, _):
                let codes: Set<String> = [
                    "AUTHENTICATION_FAILED", "NOT_AUTHENTICATED",
                    "PERMISSION_FAILURE", "AUTHENTICATION_REQUIRED"
                ]
                return codes.contains(serverErrorCode)
            default:
                return false
            }
        }
    }

    public struct ModifyRequest {
        public let operationType: ModifyOperationType
        public let recordType: String
        public let recordName: String
        public let fields: [String: [String: Any]]

        public init(
            operationType: ModifyOperationType,
            recordType: String,
            recordName: String,
            fields: [String: [String: Any]]
        ) {
            self.operationType = operationType
            self.recordType = recordType
            self.recordName = recordName
            self.fields = fields
        }
    }

    public enum ModifyOperationType: String, Sendable {
        case forceReplace = "forceReplace"
        case update = "update"
        case forceUpdate = "forceUpdate"
        case forceDelete = "forceDelete"
    }

    // MARK: - Field Value Marshaling

    /// Convert a Swift value to CK REST field format: `{"value": X, "type": "TYPE"}`.
    public static func fieldValue(_ value: Any) -> [String: Any]? {
        switch value {
        case let s as String:
            return ["value": s, "type": "STRING"]
        case let i as Int64:
            return ["value": i, "type": "INT64"]
        case let i as Int:
            return ["value": Int64(i), "type": "INT64"]
        case let d as Double:
            return ["value": d, "type": "DOUBLE"]
        case let b as Bool:
            return ["value": b ? 1 : 0, "type": "INT64"]
        case let date as Date:
            return ["value": Int64(date.timeIntervalSince1970 * 1000), "type": "TIMESTAMP"]
        case let arr as [String]:
            return ["value": arr, "type": "STRING_LIST"]
        default:
            return nil
        }
    }

    // MARK: - Query

    /// Query records via CK REST API with automatic pagination.
    /// - Parameters:
    ///   - recordType: CK record type name (e.g. "BBHeartbeat")
    ///   - filters: Array of (fieldName, comparator, fieldValue, type).
    ///     Type defaults to "STRING" if nil.
    public static func queryRecords(
        recordType: String,
        filters: [(String, String, Any, String?)]
    ) async throws -> [RESTRecord] {
        var allRecords: [RESTRecord] = []
        var continuationMarker: String? = nil

        for _ in 0..<maxPages {
            var query: [String: Any] = [
                "recordType": recordType
            ]
            if !filters.isEmpty {
                query["filterBy"] = filters.map { f in
                    return [
                        "fieldName": f.0,
                        "comparator": f.1,
                        "fieldValue": ["value": f.2, "type": f.3 ?? "STRING"]
                    ] as [String: Any]
                }
            }

            var body: [String: Any] = [
                "query": query,
                "resultsLimit": pageSize
            ]
            if let marker = continuationMarker {
                body["continuationMarker"] = marker
            }

            let result = try await post(path: "/records/query", body: body)

            guard let records = result["records"] as? [[String: Any]] else {
                break
            }

            for record in records {
                if let parsed = parseRecord(record) {
                    allRecords.append(parsed)
                }
            }

            if let marker = result["continuationMarker"] as? String {
                continuationMarker = marker
            } else {
                break
            }
        }

        return allRecords
    }

    // MARK: - Modify

    public static func modifyRecords(_ requests: [ModifyRequest]) async throws -> [RESTRecord] {
        let operations = requests.map { req -> [String: Any] in
            [
                "operationType": req.operationType.rawValue,
                "record": [
                    "recordType": req.recordType,
                    "recordName": req.recordName,
                    "fields": req.fields
                ] as [String: Any]
            ] as [String: Any]
        }

        let body: [String: Any] = ["operations": operations]
        let result = try await post(path: "/records/modify", body: body)

        guard let records = result["records"] as? [[String: Any]] else {
            if let serverErrors = result["records"] as? [Any] {
                for item in serverErrors {
                    if let dict = item as? [String: Any],
                       let serverErrorCode = dict["serverErrorCode"] as? String {
                        let reason = dict["reason"] as? String ?? ""
                        let error = RESTError.recordError(serverErrorCode: serverErrorCode, reason: reason)
                        if error.isAuthError { tripAuthCircuitBreaker() }
                        throw error
                    }
                }
            }
            return []
        }

        var results: [RESTRecord] = []
        for record in records {
            if let errorCode = record["serverErrorCode"] as? String {
                let reason = record["reason"] as? String ?? ""
                let error = RESTError.recordError(serverErrorCode: errorCode, reason: reason)
                if error.isAuthError { tripAuthCircuitBreaker() }
                throw error
            }
            if let parsed = parseRecord(record) {
                results.append(parsed)
            }
        }
        return results
    }

    // MARK: - Delete

    public static func deleteRecord(recordType: String, recordName: String) async throws {
        let body: [String: Any] = [
            "operations": [[
                "operationType": "forceDelete",
                "record": [
                    "recordType": recordType,
                    "recordName": recordName
                ]
            ]]
        ]
        _ = try await post(path: "/records/modify", body: body)
    }

    // MARK: - Internal

    private static func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        let urlString = baseURL + path + "?ckAPIToken=\(apiToken)"
            + (webAuthToken.map { "&ckWebAuthToken=\($0)" } ?? "")
        guard let url = URL(string: urlString) else {
            throw RESTError.requestFailed(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RESTError.requestFailed(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RESTError.badResponse(0)
        }

        if httpResponse.statusCode == 421 || httpResponse.statusCode == 401 {
            tripAuthCircuitBreaker()
            throw RESTError.badResponse(httpResponse.statusCode)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RESTError.badResponse(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RESTError.decodingFailed
        }

        return json
    }

    private static func parseRecord(_ dict: [String: Any]) -> RESTRecord? {
        guard let recordName = dict["recordName"] as? String,
              let recordType = dict["recordType"] as? String else {
            return nil
        }
        let rawFields = dict["fields"] as? [String: Any] ?? [:]
        var fields: [String: [String: Any]] = [:]
        for (key, val) in rawFields {
            if let fieldDict = val as? [String: Any] {
                fields[key] = fieldDict
            }
        }
        return RESTRecord(recordName: recordName, recordType: recordType, fields: fields)
    }
}

// Sendable conformance: RESTRecord holds only value types and
// [String: [String: Any]] which is effectively frozen after init.
// The @unchecked is needed because [String: Any] isn't Sendable.
extension CloudKitRESTClient.RESTRecord: @unchecked Sendable {}
extension CloudKitRESTClient.ModifyRequest: @unchecked Sendable {}
