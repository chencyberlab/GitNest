import SwiftUI

/// A self-drawn hover tooltip that replaces SwiftUI's `.help()` (AppKit
/// `NSToolTip`), which is slow to appear (multi-second OS delay) and drops out
/// when a view rebuilds under the cursor — e.g. our 10-second status refresh.
///
/// How it works: each `.tooltip(_:)` reports its frame (in a shared named
/// coordinate space) and its hover state to a single `TooltipController`. One
/// `TooltipOverlay` at the window root draws the bubble, so it floats above the
/// repo-list clip region and survives row rebuilds (the controller's state is
/// independent of any one row's view identity).
@MainActor
final class TooltipController: ObservableObject {
    static let space = "tooltipRoot"
    static let showDelay: Double = 0.3   // seconds of hover before showing

    @Published private(set) var text: String?
    @Published private(set) var anchor: CGRect = .zero

    private var pendingID: UUID?
    private var visibleID: UUID?
    private var showTask: Task<Void, Never>?

    func hover(id: UUID, text: String, anchor: CGRect) {
        self.anchor = anchor
        if visibleID == id || pendingID == id { return }
        pendingID = id
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.showDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pendingID == id else { return }
            self.pendingID = nil
            self.visibleID = id
            self.text = text
            self.anchor = anchor
        }
    }

    func endHover(id: UUID) {
        if pendingID == id { pendingID = nil; showTask?.cancel() }
        if visibleID == id { visibleID = nil; text = nil }
    }

    /// Keep the bubble glued to its control if the control moves while hovered
    /// (e.g. the list scrolls under the cursor).
    func moveAnchor(id: UUID, anchor: CGRect) {
        if visibleID == id || pendingID == id { self.anchor = anchor }
    }
}

private struct TooltipAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct TooltipSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct TooltipModifier: ViewModifier {
    let text: String
    @EnvironmentObject private var tip: TooltipController
    @State private var id = UUID()
    @State private var anchor: CGRect = .zero
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TooltipAnchorKey.self,
                                           value: geo.frame(in: .named(TooltipController.space)))
                }
            )
            .onPreferenceChange(TooltipAnchorKey.self) { newAnchor in
                anchor = newAnchor
                if hovering { tip.moveAnchor(id: id, anchor: newAnchor) }
            }
            .onHover { isHovering in
                hovering = isHovering
                if isHovering { tip.hover(id: id, text: text, anchor: anchor) }
                else { tip.endHover(id: id) }
            }
            // If the hovered control is removed (e.g. a badge dropped by the 10s
            // refresh), onHover(false) never fires — dismiss the bubble explicitly
            // so it doesn't linger until the next hover.
            .onDisappear { if hovering { tip.endHover(id: id) } }
    }
}

extension View {
    /// Drop-in replacement for `.help(_:)` using the custom hover tooltip.
    func tooltip(_ text: String) -> some View {
        modifier(TooltipModifier(text: text))
    }
}

/// The single bubble, drawn at the window root. Add it once, above everything,
/// on the view that defines `TooltipController.space`.
struct TooltipOverlay: View {
    @EnvironmentObject private var tip: TooltipController
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { root in
            if let text = tip.text {
                let a = tip.anchor
                let gap: CGFloat = 6
                let fitsBelow = a.maxY + gap + size.height <= root.size.height - 8
                let y = fitsBelow ? a.maxY + gap : max(8, a.minY - gap - size.height)
                let x = min(max(8, a.midX - size.width / 2),
                            max(8, root.size.width - size.width - 8))
                bubble(text)
                    .offset(x: x, y: y)
                    .opacity(size == .zero ? 0 : 1)   // hide the first, unmeasured frame
            }
        }
        .allowsHitTesting(false)
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.tooltipText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(Theme.tooltipBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TooltipSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(TooltipSizeKey.self) { size = $0 }
    }
}
