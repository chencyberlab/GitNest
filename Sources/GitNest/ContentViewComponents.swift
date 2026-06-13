import SwiftUI
import AppKit


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
