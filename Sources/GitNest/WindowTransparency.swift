import AppKit
import SwiftUI

/// Persisted window-transparency preferences. Off by default so the app stays
/// solid until the user opts in from Settings.
enum WindowTransparencyPreference {
    static let enabledKey = "windowTransparencyEnabled"
    static let percentKey = "windowTransparencyPercent"
    /// Legacy alias kept so older call sites / tests that reference `defaultsKey`
    /// still compile against the enabled flag.
    static let defaultsKey = enabledKey

    /// Default amount when the user first turns transparency on (readable glass).
    static let defaultPercent = 40
    /// Floor at 100% — low enough to read as glass, high enough that every pane
    /// stays in the same ballpark (no near-clear footers vs solid mid-panels).
    static let minimumPaneOpacity = 0.32

    /// Clamp a stored percent into 0…100.
    static func clampedPercent(_ raw: Int) -> Int {
        min(100, max(0, raw))
    }

    /// Single global pane opacity. Every chrome surface (sidebar, detail, list,
    /// title bar, refresh footer) must use this — no per-pane density multipliers,
    /// which made the UI look patchy.
    static func paneOpacity(percent: Int) -> Double {
        let t = Double(clampedPercent(percent)) / 100.0
        return 1.0 - t * (1.0 - minimumPaneOpacity)
    }

    /// Frost strength behind panes. Fades with the slider but stays strong enough
    /// that clear gaps don't punch straight through to the wallpaper.
    static func frostIntensity(percent: Int) -> Double {
        let t = Double(clampedPercent(percent)) / 100.0
        // 0% → 1.0; 100% → 0.45 (still a real veil, not a hole).
        return max(0.45, 1.0 - t * 0.55)
    }
}

private struct WindowTransparencyEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WindowTransparencyPercentKey: EnvironmentKey {
    static let defaultValue = WindowTransparencyPreference.defaultPercent
}

extension EnvironmentValues {
    var windowTransparencyEnabled: Bool {
        get { self[WindowTransparencyEnabledKey.self] }
        set { self[WindowTransparencyEnabledKey.self] = newValue }
    }

    /// 0 = solid panes, 100 = maximum glass (still floored for readability).
    var windowTransparencyPercent: Int {
        get { self[WindowTransparencyPercentKey.self] }
        set { self[WindowTransparencyPercentKey.self] = newValue }
    }
}

/// Configures the hosting `NSWindow` for translucent chrome (clear + non-opaque)
/// or restores the normal solid window when turned off.
enum WindowTransparency {
    /// Desired chrome flags for the toggle. Pure + testable without allocating a
    /// real `NSWindow` (creating windows in XCTest can SIGSEGV in some hosts).
    struct Chrome: Equatable, Sendable {
        var isOpaque: Bool
        var usesClearBackground: Bool
        var titlebarAppearsTransparent: Bool

        static func forEnabled(_ enabled: Bool) -> Chrome {
            // Never use a transparent title bar — that pulls NavigationSplitView
            // sidebar content up under the traffic lights and squeezes "GitNest"
            // into the controls. Glass comes from a clear window + frost + matching
            // toolbar fill instead.
            if enabled {
                return Chrome(isOpaque: false, usesClearBackground: true, titlebarAppearsTransparent: false)
            }
            return Chrome(isOpaque: true, usesClearBackground: false, titlebarAppearsTransparent: false)
        }
    }

    static func apply(_ enabled: Bool, to window: NSWindow) {
        let chrome = Chrome.forEnabled(enabled)
        window.titlebarAppearsTransparent = chrome.titlebarAppearsTransparent
        window.isOpaque = chrome.isOpaque
        window.backgroundColor = chrome.usesClearBackground ? .clear : NSColor.windowBackgroundColor
        window.titleVisibility = .visible
        // AppKit caches the opaque shadow as well as the content layout. Refresh
        // both transitions so enabling glass does not wait for a window resize.
        window.contentView?.needsLayout = true
        window.contentView?.needsDisplay = true
        window.invalidateShadow()
    }
}

/// Applies the latest preference when the bridge actually joins a window. A
/// single queued retry can run before attachment and lose the launch preference.
struct WindowTransparencyBridge: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView(frame: .zero)
        view.enabled = enabled
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.enabled = enabled
    }

    final class WindowView: NSView {
        var enabled = false {
            didSet { applyToWindow() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToWindow()
        }

        private func applyToWindow() {
            guard let window else { return }
            WindowTransparency.apply(enabled, to: window)
        }
    }
}

/// Frosted glass behind the scene content. `intensity` fades with the slider.
struct VisualEffectBackground: NSViewRepresentable {
    var intensity: Double
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.alphaValue = CGFloat(min(1, max(0, intensity)))
    }
}

/// Uniform pane fill — every chrome region should use this so transparency looks
/// the same across sidebar, detail, list, and footers.
struct PaneBackground: View {
    @Environment(\.theme) private var theme
    @Environment(\.windowTransparencyEnabled) private var transparent
    @Environment(\.windowTransparencyPercent) private var percent

    var body: some View {
        theme.surface.opacity(
            transparent
                ? WindowTransparencyPreference.paneOpacity(percent: percent)
                : 1
        )
    }
}

extension View {
    /// Installs the frosted backdrop + window chrome for the transparency setting,
    /// and publishes enabled + percent into the environment for pane fills.
    func windowTransparency(enabled: Bool, percent: Int) -> some View {
        modifier(WindowTransparencyModifier(enabled: enabled, percent: percent))
    }

    /// Glass matches the pane opacity; custom palettes supply their solid fill.
    /// With glass off, the built-in palette leaves toolbar styling to macOS.
    func gitNestToolbarBackground(transparent: Bool,
                                  percent: Int,
                                  theme: Theme) -> some View {
        let fill: Color = {
            if transparent {
                return theme.surface.opacity(WindowTransparencyPreference.paneOpacity(percent: percent))
            }
            return theme.hasCustomWindowChrome ? theme.windowChromeBackground : .clear
        }()
        return self
            .toolbarBackground(transparent || theme.hasCustomWindowChrome ? .visible : .automatic, for: .windowToolbar)
            .toolbarBackground(fill, for: .windowToolbar)
    }
}

private struct WindowTransparencyModifier: ViewModifier {
    let enabled: Bool
    let percent: Int

    private var clampedPercent: Int {
        WindowTransparencyPreference.clampedPercent(percent)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if enabled {
                    VisualEffectBackground(
                        intensity: WindowTransparencyPreference.frostIntensity(percent: clampedPercent)
                    )
                    .ignoresSafeArea()
                }
            }
            // Zero-size bridge so it doesn't affect layout; still joins the view
            // hierarchy so it can find the hosting NSWindow.
            .background {
                WindowTransparencyBridge(enabled: enabled)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .environment(\.windowTransparencyEnabled, enabled)
            .environment(\.windowTransparencyPercent, clampedPercent)
    }
}
