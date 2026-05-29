import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.trafficlight.app", category: "main")

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var windowDetector: WindowDetector!
    private var trafficLightManager: TrafficLightManager!
    private var processMonitor: ProcessMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application did finish launching")

        // Request Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logger.info("Accessibility permission: \(trusted ? "YES" : "NO")")

        // Setup status bar first
        setupStatusBar()

        // Hide from Dock - show only in menu bar
        NSApp.setActivationPolicy(.accessory)

        // Initialize components
        processMonitor = ProcessMonitor()
        windowDetector = WindowDetector()
        trafficLightManager = TrafficLightManager(
            windowDetector: windowDetector,
            processMonitor: processMonitor
        )

        // Start monitoring
        trafficLightManager.startMonitoring()

        // Activate the app
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Traffic Light")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
