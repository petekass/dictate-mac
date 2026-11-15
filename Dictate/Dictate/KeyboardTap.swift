import AppKit
import CoreGraphics

/// Session event tap that swallows keys while a dictation runs (Esc to cancel, Space for
/// hands-free). An NSEvent monitor cannot swallow keys, and a stray Esc would e.g. interrupt
/// a running task in a terminal app. The tap is only enabled during a dictation, so the
/// keyboard never waits on Dictate otherwise.
@MainActor
final class KeyboardTap {
    enum KeyAction {
        case pass
        case swallow
    }

    /// Return `.swallow` to keep the key from reaching the frontmost app.
    var onKeyDown: ((_ keyCode: Int64, _ flags: CGEventFlags, _ isRepeat: Bool) -> KeyAction)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Returns false when macOS refuses the tap (Accessibility permission missing).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyboardTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            appLog.error("keyboard tap unavailable; Esc cancel and hands-free are off")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: isActive)
        self.tap = tap
        self.source = source
        return true
    }

    private var isActive = false

    func setActive(_ active: Bool) {
        isActive = active
        if let tap { CGEvent.tapEnable(tap: tap, enable: active) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap, isActive { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if onKeyDown?(keyCode, event.flags, isRepeat) == .swallow {
                return nil
            }
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
