import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "com.trafficlight.app", category: "manager")

/// Manages traffic light windows for each Claude terminal
class TrafficLightManager {
    private let windowDetector: WindowDetector
    private let processMonitor: ProcessMonitor
    private var trafficLightWindows: [ClaudeWindow: TrafficLightPanel] = [:]
    private var timer: Timer?
    private var previousWindows: Set<ClaudeWindow> = []

    init(windowDetector: WindowDetector, processMonitor: ProcessMonitor) {
        self.windowDetector = windowDetector
        self.processMonitor = processMonitor
    }

    func startMonitoring() {
        logger.info("startMonitoring called")

        // Check every 0.5 seconds on main run loop
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTrafficLights()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTrafficLights() {
        let currentWindows = Set(windowDetector.detectClaudeWindows())
        logger.info("Detected \(currentWindows.count) Claude windows")

        // Remove traffic lights for closed windows
        for window in previousWindows {
            if !currentWindows.contains(window) {
                trafficLightWindows[window]?.close()
                trafficLightWindows.removeValue(forKey: window)
            }
        }

        // Add traffic lights for new windows
        for window in currentWindows {
            let exists = trafficLightWindows.keys.contains(where: { $0 == window })
            if !exists {
                logger.info("Creating traffic light for: \(window.appName)")
                let panel = TrafficLightPanel(claudeWindow: window, processMonitor: processMonitor)
                trafficLightWindows[window] = panel
                panel.show()
            }
        }

        // Update positions based on terminal window positions
        for (window, panel) in trafficLightWindows {
            if let updatedWindow = currentWindows.first(where: { $0 == window }) {
                panel.updatePosition(near: updatedWindow.frame)
            }
        }

        previousWindows = currentWindows
    }
}
