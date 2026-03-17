import AppKit
import Combine
import Foundation

final class TaskSessionRecord: ObservableObject, Identifiable {
    let id = UUID()

    weak var panel: FloatingPanel?

    @Published var title: String
    @Published var subtitle: String
    @Published var icon: NSImage?
    @Published var startedAt: Date
    @Published var completedAt: Date?
    @Published var lastActivityAt: Date
    @Published var isWindowVisible: Bool
    @Published var isRunning: Bool

    init(panel: FloatingPanel) {
        let startedAt = panel.taskStartedAt ?? Date()

        self.panel = panel
        self.title = panel.taskDisplayTitle
        self.subtitle = panel.taskDisplaySubtitle
        self.icon = panel.taskDisplayIcon
        self.startedAt = startedAt
        self.completedAt = panel.taskCompletedAt
        self.lastActivityAt = panel.taskLastActivityAt ?? startedAt
        self.isWindowVisible = panel.isVisible
        self.isRunning = panel.isTaskRunning
    }

    func sync(from panel: FloatingPanel) {
        self.panel = panel
        title = panel.taskDisplayTitle
        subtitle = panel.taskDisplaySubtitle
        icon = panel.taskDisplayIcon
        startedAt = panel.taskStartedAt ?? startedAt
        completedAt = panel.taskCompletedAt
        lastActivityAt = panel.taskLastActivityAt ?? lastActivityAt
        isWindowVisible = panel.isVisible
        isRunning = panel.isTaskRunning
    }
}
