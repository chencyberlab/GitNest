import SwiftUI


/// Collects each account card's frame (in the account-list coordinate space) so
/// drag-to-reorder can map the finger position to a drop slot.
struct AccountCardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ActionIconButton: View {
    let systemName: String
    let help: String
    let tint: Color?
    let fill: Color?
    let action: () -> Void

    @State var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(IconChipButtonStyle(tint: tint, fill: fill, isHovered: isHovering))
        .tooltip(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

/// Brand selection background (replaces the system blue highlight).
struct SelectionBackground: View {
    let selected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .fill(selected ? theme.accentSubtle : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
    }
}

/// A single tappable row used inside the cloned-repo Open menu popover.
/// The row itself has no background; the whole popover shares one surface,
/// and a subtle accent highlight fades in on hover to show the target item.
struct OpenPopoverRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMicro, style: .continuous)
                        .fill(isHovering ? theme.accentSubtle : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

struct ActionPopoverButton<PopoverContent: View>: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    var fill: Color? = nil
    let content: (Binding<Bool>) -> PopoverContent

    @State var isHovering = false
    @State var isPresented = false

    init(systemName: String,
         help: String,
         tint: Color? = nil,
         fill: Color? = nil,
         @ViewBuilder content: @escaping (Binding<Bool>) -> PopoverContent) {
        self.systemName = systemName
        self.help = help
        self.tint = tint
        self.fill = fill
        self.content = content
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: systemName)
        }
        .buttonStyle(IconChipButtonStyle(tint: tint, fill: fill, isHovered: isHovering || isPresented))
        .tooltip(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content($isPresented)
                .onDisappear {
                    if isPresented { isPresented = false }
                }
        }
    }
}
