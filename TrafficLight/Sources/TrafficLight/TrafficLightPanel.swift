import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.trafficlight.app", category: "panel")

/// Floating panel that displays a traffic light for a Claude window
class TrafficLightPanel: NSPanel {
    private let claudeWindow: ClaudeWindow
    private var hostingView: NSHostingView<TrafficLightView>?
    private var currentState: TrafficLightState = .green

    init(claudeWindow: ClaudeWindow) {
        self.claudeWindow = claudeWindow

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 100),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false

        setupView()
    }

    private func setupView() {
        let view = TrafficLightView(state: currentState)
        hostingView = NSHostingView(rootView: view)
        contentView = hostingView
    }

    func show() {
        makeKeyAndOrderFront(nil)
    }

    func updatePosition(near terminalFrame: CGRect) {
        // Position at top-left corner of terminal window (with small offset)
        let x = terminalFrame.origin.x + 5

        // Convert from CGDisplay coordinates to AppKit coordinates
        let screenFrame = NSScreen.main?.frame ?? NSRect.zero
        // CGDisplay Y is from top-left, AppKit Y is from bottom-left
        let terminalTopInCG = terminalFrame.origin.y + terminalFrame.height
        let appKitY = screenFrame.height - terminalTopInCG - 5

        setFrameOrigin(NSPoint(x: x, y: appKitY))
    }

    private func startMonitoring() {
        // Monitoring is owned by TrafficLightManager now; nothing to do here.
    }

    /// Push a new state in from the manager.
    func apply(state: TrafficLightState) {
        guard state != currentState else { return }
        currentState = state
        updateView()
    }

    private func checkState() {
        // Deprecated path kept only to avoid breaking callers; manager pushes state.
    }

    private func updateView() {
        let view = TrafficLightView(state: currentState)
        hostingView?.rootView = view
    }

    private func focusTerminal() {
        // Raise the specific terminal window for this Claude instance
        // (not just any window of the app), then activate the app.
        // CGWindow and AXUIElement use the same flipped-screen coordinate
        // space (top-left origin), so we can compare their frames directly.
        let appRef = AXUIElementCreateApplication(claudeWindow.processID)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            var best: (AXUIElement, CGFloat)? = nil
            for w in windows {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
                      AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
                      let p = posRef, let s = sizeRef else { continue }
                var pt = CGPoint.zero, sz = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &pt)
                AXValueGetValue(s as! AXValue, .cgSize, &sz)
                let dx = pt.x - claudeWindow.frame.origin.x
                let dy = pt.y - claudeWindow.frame.origin.y
                let dw = sz.width - claudeWindow.frame.width
                let dh = sz.height - claudeWindow.frame.height
                let dist = dx * dx + dy * dy + dw * dw + dh * dh
                if best == nil || dist < best!.1 { best = (w, dist) }
            }
            if let (target, _) = best {
                AXUIElementPerformAction(target, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
        NSRunningApplication(processIdentifier: claudeWindow.processID)?
            .activate(options: [.activateIgnoringOtherApps])
    }

    // Click handling.
    //
    // Single click = focus terminal. Drag = move panel.
    //
    // Implementation note: we must NOT call the blocking performDrag from
    // mouseDown — that pumps the run loop until mouse-up and previously left
    // the cursor stuck as "loading" on bare clicks. Instead:
    //   mouseDown    -> remember start, return immediately
    //   mouseDragged -> once moved past threshold, performDrag (it's now
    //                   guaranteed to receive a mouse-up and exit cleanly)
    //   mouseUp      -> if we never crossed the drag threshold, treat as
    //                   click and focus the terminal.
    private var mouseDownLocation: NSPoint = .zero
    private var didDrag: Bool = false
    private let dragThreshold: CGFloat = 4.0

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        let dx = p.x - mouseDownLocation.x
        let dy = p.y - mouseDownLocation.y
        if !didDrag && (dx * dx + dy * dy) >= dragThreshold * dragThreshold {
            didDrag = true
            performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { return }
        focusTerminal()
    }

    deinit {
    }
}

// MARK: - Traffic Light View (3 lights: red, yellow, green)
struct TrafficLightView: View {
    let state: TrafficLightState
    // Click handling is owned by NSPanel.mouseDown/mouseUp; SwiftUI gestures
    // here would only fight with that.

    var body: some View {
        ZStack {
            // Background - comic style dark frame
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
                .frame(width: 36, height: 92)

            // Inner background with gradient
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.2), Color(white: 0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 32, height: 88)

            // Three lights stacked vertically
            VStack(spacing: 6) {
                LightView(color: .red,    isOn: state == .red,    isGlowing: state == .red)
                LightView(color: .yellow, isOn: state == .yellow, isGlowing: state == .yellow)
                LightView(color: .green,  isOn: state == .green,  isGlowing: state == .green)
            }
        }
        .frame(width: 40, height: 100)
        // Let mouse events fall through to the hosting NSPanel.
        .allowsHitTesting(false)
    }
}

// MARK: - Single Light View
struct LightView: View {
    let color: LightColor
    let isOn: Bool
    let isGlowing: Bool

    @State private var glowAnimation = false

    var body: some View {
        ZStack {
            // Outer glow when on
            if isOn && isGlowing {
                Circle()
                    .fill(color.glowColor)
                    .frame(width: 24, height: 24)
                    .blur(radius: glowAnimation ? 6 : 3)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: glowAnimation)
            }

            // Light base (dark circle)
            Circle()
                .fill(Color(white: 0.15))
                .frame(width: 20, height: 20)

            // Light bulb
            Circle()
                .fill(
                    RadialGradient(
                        colors: isOn
                            ? [color.brightColor, color.baseColor, color.darkColor]
                            : [Color(white: 0.3), Color(white: 0.25), Color(white: 0.2)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: 18, height: 18)

            // Highlight reflection (comic style)
            if isOn {
                Circle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .offset(x: -4, y: -4)
            }
        }
        .onAppear {
            if isOn && isGlowing {
                glowAnimation = true
            }
        }
        .onChange(of: isGlowing) { newValue in
            glowAnimation = newValue
        }
    }
}

// MARK: - Light Color
enum LightColor {
    case red, yellow, green

    var baseColor: Color {
        switch self {
        case .red: return Color(red: 0.9, green: 0.2, blue: 0.2)
        case .yellow: return Color(red: 0.95, green: 0.8, blue: 0.2)
        case .green: return Color(red: 0.2, green: 0.85, blue: 0.3)
        }
    }

    var brightColor: Color {
        switch self {
        case .red: return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .yellow: return Color(red: 1.0, green: 0.95, blue: 0.5)
        case .green: return Color(red: 0.4, green: 1.0, blue: 0.5)
        }
    }

    var darkColor: Color {
        switch self {
        case .red: return Color(red: 0.6, green: 0.1, blue: 0.1)
        case .yellow: return Color(red: 0.7, green: 0.6, blue: 0.1)
        case .green: return Color(red: 0.1, green: 0.5, blue: 0.2)
        }
    }

    var glowColor: Color {
        switch self {
        case .red: return Color.red.opacity(0.6)
        case .yellow: return Color.yellow.opacity(0.6)
        case .green: return Color.green.opacity(0.6)
        }
    }
}
