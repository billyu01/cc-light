import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.trafficlight.app", category: "manager")

/// Manages traffic light windows for each Claude terminal.
///
/// Threading model (this matters — see "stuck cursor" bug):
///   - Heavy work (pgrep / ps fork+exec, AX tree traversal) runs on a
///     background serial queue. None of it touches the main thread.
///   - Only the final UI mutation (creating/closing panels, applying state)
///     hops back to the main thread.
///   - Timer ticks are coalesced: if a previous tick is still running we
///     skip this one rather than queue them up.
class TrafficLightManager {
    private let windowDetector: WindowDetector
    private let processMonitor: ProcessMonitor
    private var trafficLightWindows: [ClaudeWindow: TrafficLightPanel] = [:]
    private var timer: Timer?

    private let workQueue = DispatchQueue(label: "com.trafficlight.work", qos: .utility)
    private var tickInFlight = false

    init(windowDetector: WindowDetector, processMonitor: ProcessMonitor) {
        self.windowDetector = windowDetector
        self.processMonitor = processMonitor
    }

    func startMonitoring() {
        logger.info("startMonitoring called")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.scheduleTick()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleTick() {
        // Coalesce: if last tick is still running (e.g. AX call is slow), skip.
        // We'd rather drop a sample than back up the work queue.
        if tickInFlight { return }
        tickInFlight = true
        workQueue.async { [weak self] in
            self?.tick()
            self?.tickInFlight = false
        }
    }

    /// Background-thread tick. Reads windows + state, then hops to main for UI.
    private func tick() {
        let currentWindows = windowDetector.detectClaudeWindows()

        // Compute the (window -> state) map off the main thread. ProcessMonitor
        // is only touched here, on this serial work queue, so no locking needed.
        var states: [ClaudeWindow: TrafficLightState] = [:]
        for w in currentWindows {
            states[w] = processMonitor.getState(for: w)
        }
        processMonitor.prune(activeWindows: currentWindows)

        // Apply to UI on the main thread. This is fast: dictionary diff +
        // setting properties on NSPanels.
        DispatchQueue.main.async { [weak self] in
            self?.applyToUI(currentWindows: currentWindows, states: states)
        }
    }

    private func applyToUI(currentWindows: [ClaudeWindow], states: [ClaudeWindow: TrafficLightState]) {
        let currentSet = Set(currentWindows)

        // Drop panels for windows that disappeared.
        for (window, panel) in trafficLightWindows where !currentSet.contains(window) {
            panel.close()
            trafficLightWindows.removeValue(forKey: window)
        }

        // Spin up panels for new windows.
        for window in currentWindows where trafficLightWindows[window] == nil {
            let panel = TrafficLightPanel(claudeWindow: window)
            trafficLightWindows[window] = panel
            panel.show()
        }

        // Update each panel: position + state.
        for window in currentWindows {
            guard let panel = trafficLightWindows[window] else { continue }
            panel.updatePosition(near: window.frame)
            if let state = states[window] {
                panel.apply(state: state)
            }
        }
    }
}
