import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "com.trafficlight.app", category: "manager")

/// Manages traffic light windows for each Claude terminal.
///
/// Owns the *only* polling timer in the app: every tick it (1) refreshes the
/// list of Claude windows, (2) asks ProcessMonitor for each window's state,
/// (3) pushes that state into the matching panel. This keeps the AX reads
/// serialized and avoids per-panel timers racing each other.
class TrafficLightManager {
    private let windowDetector: WindowDetector
    private let processMonitor: ProcessMonitor
    private var trafficLightWindows: [ClaudeWindow: TrafficLightPanel] = [:]
    private var timer: Timer?

    init(windowDetector: WindowDetector, processMonitor: ProcessMonitor) {
        self.windowDetector = windowDetector
        self.processMonitor = processMonitor
    }

    func startMonitoring() {
        logger.info("startMonitoring called")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.tick()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let currentWindows = windowDetector.detectClaudeWindows()
        let currentSet = Set(currentWindows)
        logger.info("Detected \(currentWindows.count) Claude windows")

        // Drop panels for windows that disappeared.
        for (window, panel) in trafficLightWindows where !currentSet.contains(window) {
            panel.close()
            trafficLightWindows.removeValue(forKey: window)
        }

        // Spin up panels for new windows.
        for window in currentWindows where trafficLightWindows[window] == nil {
            logger.info("Creating traffic light for: \(window.appName)")
            let panel = TrafficLightPanel(claudeWindow: window)
            trafficLightWindows[window] = panel
            panel.show()
        }

        // Update each panel: position + state. Reading state here (instead of
        // in each panel) means ProcessMonitor sees one call per window per
        // tick, in deterministic order — fixes the cross-terminal interference.
        for window in currentWindows {
            guard let panel = trafficLightWindows[window] else { continue }
            panel.updatePosition(near: window.frame)
            let state = processMonitor.getState(for: window)
            panel.apply(state: state)
        }

        // Free per-window tracking for windows that no longer exist.
        processMonitor.prune(activeWindows: currentWindows)
    }
}
