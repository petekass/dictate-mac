import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct DictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.dictateManager)
        } label: {
            MenuBarIconView(manager: appDelegate.dictateManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}

struct MenuBarIconView: View {
    @ObservedObject var manager: DictateManager

    var body: some View {
        Image(systemName: manager.statusIcon)
            .symbolRenderingMode(usesColor ? .palette : .hierarchical)
            .foregroundStyle(iconColor)
            .id("\(manager.statusIcon)-\(manager.isRecording)-\(manager.isProcessing)-\(manager.lastIssue?.date.timeIntervalSince1970 ?? 0)")
    }

    private var usesColor: Bool {
        manager.isRecording || (!manager.isProcessing && manager.lastIssue != nil)
    }

    private var iconColor: Color {
        if manager.isRecording { return .red }
        if !manager.isProcessing, let issue = manager.lastIssue {
            return issue.isWarning ? .orange : .red
        }
        return .primary
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let dictateManager = DictateManager()
    private var eventMonitor: Any?
    private let keyboardTap = KeyboardTap()
    private var hotkeyWasDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermissions()
        setupGlobalHotkey()
        setupKeyboardTap()
    }

    private func setupKeyboardTap() {
        keyboardTap.onKeyDown = { [weak self] keyCode, _ in
            guard let manager = self?.dictateManager else { return .pass }
            switch keyCode {
            case 53 where manager.isRecording || manager.isProcessing: // Esc
                manager.cancelDictation()
                return .swallow
            case 49 where manager.isRecording && manager.hotkeyHeld: // Space while holding the hotkey
                manager.enterHandsFree()
                return .swallow
            default:
                return .pass
            }
        }
        if !keyboardTap.start() {
            // Accessibility may be granted later; retry once it is.
            Task { @MainActor [weak self] in
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if AXIsProcessTrusted(), self?.keyboardTap.start() == true { return }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private nonisolated func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func setupGlobalHotkey() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let hotkeyPressed: Bool
        switch dictateManager.hotkey {
        case .leftOption:
            hotkeyPressed = event.modifierFlags.contains(.option) && event.keyCode == 58
        case .fn:
            hotkeyPressed = event.modifierFlags.contains(.function)
        }

        let pressedNow = hotkeyPressed && !hotkeyWasDown
        let releasedNow = !hotkeyPressed && hotkeyWasDown
        hotkeyWasDown = hotkeyPressed
        dictateManager.hotkeyHeld = hotkeyPressed

        if pressedNow {
            if dictateManager.isRecording && dictateManager.isHandsFree {
                dictateManager.stopRecording()
            } else if !dictateManager.isRecording && !dictateManager.isProcessing {
                dictateManager.startRecording()
            }
        } else if releasedNow && dictateManager.isRecording && !dictateManager.isHandsFree {
            dictateManager.stopRecording()
        }
    }
}
