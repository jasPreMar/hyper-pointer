import AppKit
import SwiftUI

// Global reference for CGEventTap callback (C function pointers can't capture context)
private weak var sharedAppDelegate: AppDelegate?

// CGEventTap callback — must be a free function (no closures allowed)
private func rightClickCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Re-enable if system disabled the tap due to timeout
    if type == .tapDisabledByTimeout {
        if let tap = sharedAppDelegate?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .rightMouseDown else {
        return Unmanaged.passRetained(event)
    }

    // Convert CG coordinates (top-left origin) to NS coordinates (bottom-left origin)
    let cgLocation = event.location
    if let screen = NSScreen.main {
        let nsPoint = NSPoint(
            x: cgLocation.x,
            y: screen.frame.height - cgLocation.y
        )
        DispatchQueue.main.async {
            sharedAppDelegate?.createNewPanel(at: nsPoint)
        }
    }

    // Return nil to suppress the native context menu
    return nil
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panels: [FloatingPanel] = []
    var hotKeyMonitor: Any?
    fileprivate var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedAppDelegate = self
        setupRightClickTap()

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

    private func setupRightClickTap() {
        let eventMask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: rightClickCallback,
            userInfo: nil
        ) else {
            print("Failed to create event tap — ensure Accessibility permissions are granted.")
            return
        }

        eventTap = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func createNewPanel() {
        panels.removeAll { !$0.isVisible }

        let panel = FloatingPanel()
        panels.append(panel)
        panel.show()
    }

    func createNewPanel(at point: NSPoint) {
        // Close any existing search-mode panels (no message sent yet)
        for panel in panels where panel.isVisible && !panel.searchViewModel.isChatMode {
            panel.close()
        }
        panels.removeAll { !$0.isVisible }

        let panel = FloatingPanel()
        panels.append(panel)
        panel.show(at: point)
    }
}
