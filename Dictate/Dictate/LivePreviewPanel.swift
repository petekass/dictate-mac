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
    private var hosting: NSHostingView<LivePreviewView>?

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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window is larger than the card; an AppKit shadow would trace the transparent area
        // and go stale as the card grows, so the card draws its own shadow.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: LivePreviewView(model: model, layout: .init()))
        // The window keeps the frame set in position(); content must never resize it,
        // a window that followed its content grew off the bottom of the screen.
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    /// A fixed window sized for the tallest card, at the top centre of the screen with the mouse,
    /// just below the menu bar. Chat apps keep their input at the bottom, so the card stays clear of it.
    /// The card sits at the top of the window, so it grows downwards as text arrives.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let margin = PreviewLayout.shadowMargin
        let cardTop = visible.maxY - 8
        let chrome = PreviewLayout.chromeHeight
        let roomForText = cardTop - visible.minY - chrome - margin - 48
        let layout = PreviewLayout(
            cardWidth: visible.width >= 1600 ? 360 : 300,
            maxTextHeight: max(PreviewLayout.lineHeight, min(PreviewLayout.lineHeight * 8, roomForText))
        )
        let size = NSSize(width: layout.cardWidth + 2 * margin, height: layout.maxTextHeight + chrome + 2 * margin)
        hosting?.rootView = LivePreviewView(model: model, layout: layout)
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: cardTop + margin - size.height,
                              width: size.width, height: size.height), display: false)
    }
}

private struct PreviewLayout {
    static let fontSize: CGFloat = 13
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))
    /// Header row, spacing and vertical padding of the card around the text.
    static let chromeHeight: CGFloat = 52
    /// Transparent border around the card that leaves room for its shadow.
    static let shadowMargin: CGFloat = 24

    var cardWidth: CGFloat = 300
    var maxTextHeight: CGFloat = lineHeight * 8
}

private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LivePreviewView: View {
    @ObservedObject var model: LivePreviewModel
    let layout: PreviewLayout
    @State private var textHeight: CGFloat = 0

    /// Only the end of a long dictation is laid out; the top fade hides the start anyway.
    private let maxCharacters = 2000
    private let fadeHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .padding(PreviewLayout.shadowMargin)
    }

    private var card: some View {
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
            textArea
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: layout.cardWidth, alignment: .leading)
        .background {
            // Shadow on the background only, so the text does not cast one.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    /// The text keeps its full height and is pinned to the bottom of a frame of at most
    /// `maxTextHeight`, so the newest line is always visible and older lines leave at the top.
    private var textArea: some View {
        let overflows = textHeight > layout.maxTextHeight
        return text
            .font(.system(size: PreviewLayout.fontSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
            .frame(height: min(textHeight, layout.maxTextHeight), alignment: .bottom)
            .clipped()
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflows ? fadeHeight : 0)
                    Color.black
                }
            }
    }

    private var text: Text {
        let committed = model.committed
        let partial = model.partial
        if committed.isEmpty && partial.isEmpty {
            return Text(model.note == nil ? "Speak now…" : "Still recording…").foregroundColor(.secondary)
        }
        let partialPart = Self.wordTail(partial, limit: maxCharacters)
        let committedPart = Self.wordTail(committed, limit: maxCharacters - partialPart.count)
        let separator = committedPart.isEmpty || partialPart.isEmpty ? "" : " "
        // Label colours instead of .primary/.secondary: those blend with the material behind them,
        // which breaks inside the fade mask (white text in light mode).
        return Text(committedPart + separator).foregroundColor(Color(nsColor: .labelColor))
            + Text(partialPart).foregroundColor(Color(nsColor: .secondaryLabelColor))
    }

    /// The last `limit` characters of `string`, starting at a word.
    private static func wordTail(_ string: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard string.count > limit else { return string }
        let tail = string.suffix(limit)
        guard let space = tail.firstIndex(where: \.isWhitespace) else { return String(tail) }
        return String(tail[tail.index(after: space)...])
    }
}
