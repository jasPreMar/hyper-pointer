import Foundation

/// A single message in a chat conversation, replacing the previous tuple-based storage.
struct ChatMessage: Identifiable {
    let id: String
    let role: String
    let text: String
    let events: [StreamEvent]
    let structuredUI: UIResponse?

    init(
        id: String = UUID().uuidString,
        role: String,
        text: String,
        events: [StreamEvent] = [],
        structuredUI: UIResponse? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.events = events
        self.structuredUI = structuredUI
    }
}
