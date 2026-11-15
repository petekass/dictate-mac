import AppKit
import ApplicationServices

/// Read-only Accessibility access to the text field the user is typing in.
/// Field contents are only ever compared in memory; never log or store them.
enum FocusedText {
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// The focused text element. Some Electron apps (e.g. T3 Code) report no focused element
    /// to the system-wide query, so the frontmost window is searched for the focused field.
    static func element() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let element = focusedRef as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.25)
            if let role = string(element, kAXRoleAttribute), textRoles.contains(role) {
                return element
            }
        }

        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        // Bounded in elements and in time: this runs on the main thread.
        var budget = 4000
        let deadline = Date().addingTimeInterval(0.15)
        return findFocusedField(in: windowRef as! AXUIElement, depth: 0, budget: &budget, deadline: deadline)
    }

    static func value(of element: AXUIElement) -> String? {
        string(element, kAXValueAttribute)
    }

    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    enum CaretContext {
        case character(Character)
        case startOfText
        case unknown
    }

    static func characterBeforeCaret() -> CaretContext {
        guard let element = element(), let range = selectedRange(of: element) else { return .unknown }
        if range.location <= 0 { return .startOfText }

        var previous = CFRange(location: range.location - 1, length: 1)
        if let previousValue = AXValueCreate(.cfRange, &previous) {
            var stringRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          previousValue, &stringRef) == .success,
               let string = stringRef as? String, let character = string.last {
                return .character(character)
            }
        }
        // Some fields only expose their whole value.
        guard let value = value(of: element) else { return .unknown }
        let utf16 = Array(value.utf16)
        guard range.location <= utf16.count,
              let character = String(utf16CodeUnits: [utf16[range.location - 1]], count: 1).first else { return .unknown }
        return .character(character)
    }

    private static func findFocusedField(in element: AXUIElement, depth: Int, budget: inout Int,
                                         deadline: Date) -> AXUIElement? {
        budget -= 1
        guard budget > 0, depth < 60, Date() < deadline else { return nil }
        if let role = string(element, kAXRoleAttribute), textRoles.contains(role) {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focused) == .success,
               (focused as? Bool) == true {
                return element
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findFocusedField(in: child, depth: depth + 1, budget: &budget, deadline: deadline) {
                return found
            }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
