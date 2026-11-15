import AppKit
import SwiftUI

/// Live text shown while dictating with the ElevenLabs Live engine.
/// Kept apart from DictateManager so several updates per second only redraw this view,
/// never the menu bar label or the menu with its pickers.
@MainActor
final class LivePreviewModel: ObservableObject {
    enum Phase {
        case listening
        case finishing
    }

    @Published var committed = ""
    @Published var partial = ""
    @Published var phase: Phase = .listening
    @Published var note: String?
    @Published var handsFreeHint: String?

    func reset() {
        committed = ""
        partial = ""
        phase = .listening
        note = nil
        handsFreeHint = nil
    }
}

/// A panel that never becomes key or main, so the paste still goes to the app the user is typing in.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LivePreviewPanel {
    let model = LivePreviewModel()
    private var panel: NSPanel?
    private let width: CGFloat = 560

    func show() {
        model.reset()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func update(committed: String, partial: String) {
        model.committed = committed
        model.partial = partial
    }

    func setFinishing() {
        model.phase = .finishing
    }

    func setNote(_ note: String) {
        model.note = note
    }

    func setHandsFree(hint: String) {
        model.handsFreeHint = hint
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: LivePreviewView(model: model, width: width))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        return panel
    }

    /// Bottom centre of the screen with the mouse; the panel grows upwards from there.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 48))
    }
}

private struct LivePreviewView: View {
    @ObservedObject var model: LivePreviewModel
    let width: CGFloat

    /// Only the end of a long dictation is shown so the panel stays small.
    private let maxCharacters = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.phase == .listening ? Color.red : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.phase == .listening ? "Listening" : "Finishing…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if let hint = model.handsFreeHint, model.phase == .listening {
                    Text("· " + hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let note = model.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            text
                .font(.system(size: 15))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var text: Text {
        let committed = model.committed
        let partial = model.partial
        if committed.isEmpty && partial.isEmpty {
            return Text(model.note == nil ? "Speak now…" : "Still recording…").foregroundColor(.secondary)
        }
        // Trim from the front so the newest words stay visible.
        let partialPart = String(partial.suffix(maxCharacters))
        let committedPart = String(committed.suffix(max(0, maxCharacters - partialPart.count)))
        let truncated = committedPart.count < committed.count || partialPart.count < partial.count
        let separator = committedPart.isEmpty || partialPart.isEmpty ? "" : " "
        return Text((truncated ? "…" : "") + committedPart + separator).foregroundColor(.primary)
            + Text(partialPart).foregroundColor(.secondary)
    }
}
