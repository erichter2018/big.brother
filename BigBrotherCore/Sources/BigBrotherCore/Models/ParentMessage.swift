import Foundation

/// A message sent from parent to child, displayed as notification + persistent card.
public struct ParentMessage: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public let sentAt: Date
    public let sentBy: String
    public var dismissed: Bool

    public init(id: UUID = UUID(), text: String, sentAt: Date = Date(), sentBy: String, dismissed: Bool = false) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
        self.sentBy = sentBy
        self.dismissed = dismissed
    }
}
