import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panels: [FloatingPanel] = []
    var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Global hotkey: Control + Space to create new panel
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 49 {
                self?.createNewPanel()
            }
        }

        // Also monitor local events so it works when our app is active
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 49 {
                self?.createNewPanel()
                return nil
            }
            return event
        }
    }

    func createNewPanel() {
        // Clean up closed panels
        panels.removeAll { !$0.isVisible }

        let panel = FloatingPanel()
        panels.append(panel)
        panel.show()
    }
}
