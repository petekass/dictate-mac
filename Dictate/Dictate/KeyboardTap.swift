import AppKit
import CoreGraphics

/// Session event tap that can swallow keys while a dictation runs (Esc to cancel, Space to
/// switch to hands-free) and notices typing or clicks between dictations (smart spacing).
/// An NSEvent monitor cannot swallow keys, and a stray Esc would e.g. interrupt a running
/// turn in a terminal app.
@MainActor
final class KeyboardTap {
    enum KeyAction {
        case pass
        case swallow
    }

    /// Return `.swallow` to keep the key from reaching the frontmost app.
    var onKeyDown: ((_ keyCode: Int64, _ flags: CGEventFlags) -> KeyAction)?
    /// Any real key press or mouse click that was passed on.
    var onUserInput: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Returns false when macOS refuses the tap (Accessibility permission missing).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyboardTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            appLog.error("keyboard tap unavailable; Esc cancel, hands-free and smart spacing are off")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if onKeyDown?(keyCode, event.flags) == .swallow {
                return nil
            }
            // Dictate's own Cmd+V paste is not user input.
            if !(keyCode == 9 && event.flags.contains(.maskCommand)) {
                onUserInput?()
            }
        case .leftMouseDown, .rightMouseDown:
            onUserInput?()
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

/// The tap's run loop source lives on the main run loop, so this runs on the main thread.
private func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyboardTap>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        tap.handle(type: type, event: event)
    }
}
