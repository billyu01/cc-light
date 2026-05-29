import Foundation
import Cocoa
import os.log

private let logger = Logger(subsystem: "com.trafficlight.app", category: "monitor")

// File logger for debugging
private func logToFile(_ message: String) {
    let logPath = "/tmp/trafficlight_debug.log"
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let fileHandle = FileHandle(forWritingAtPath: logPath) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            try? fileHandle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

/// Traffic light state
enum TrafficLightState {
    case red      // Content is changing (Claude is outputting)
    case yellow   // Waiting for user selection
    case green    // Completed/ready
}

/// Monitors Claude Code terminal output via Accessibility API
class ProcessMonitor {
    private var lastContentHash: [pid_t: Int] = [:]
    private var lastState: [pid_t: TrafficLightState] = [:]

    /// Get the current state for a Claude window
    func getState(for window: ClaudeWindow) -> TrafficLightState {
        // Get terminal content via Accessibility API
        guard let content = getTerminalContent(for: window) else {
            logToFile("Failed to get terminal content for pid \(window.processID)")
            return lastState[window.processID] ?? .green
        }

        logToFile("Got content length: \(content.count)")

        let state = analyzeContent(content, for: window.processID)
        lastState[window.processID] = state
        return state
    }

    /// Get terminal content via Accessibility API
    private func getTerminalContent(for window: ClaudeWindow) -> String? {
        let appRef = AXUIElementCreateApplication(window.processID)

        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windows)

        guard result == .success, let windowList = windows as? [AXUIElement] else {
            return nil
        }

        for axWindow in windowList {
            // Try to get text content
            if let content = extractTextFromElement(axWindow) {
                return content
            }
        }

        return nil
    }

    /// Recursively extract text from AXUIElement
    private func extractTextFromElement(_ element: AXUIElement) -> String? {
        // Try to get value directly
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)

        if let text = value as? String, text.count > 50 {
            return text
        }

        // Try to get children and search recursively
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)

        guard let childList = children as? [AXUIElement] else {
            return nil
        }

        for child in childList {
            // Check role
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)

            if let r = role as? String {
                // Look for text-related roles
                if r == "AXTextArea" || r == "AXStaticText" || r == "AXWebArea" {
                    var childValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &childValue)

                    if let text = childValue as? String, text.count > 50 {
                        return text
                    }
                }
            }

            // Recursively search
            if let text = extractTextFromElement(child) {
                return text
            }
        }

        return nil
    }

    /// Analyze content to determine state
    private func analyzeContent(_ content: String, for pid: pid_t) -> TrafficLightState {
        let lines = content.components(separatedBy: "\n")
        let lastLines = lines.suffix(30).joined(separator: "\n").lowercased()

        // Check if content changed
        let currentHash = content.hashValue
        let previousHash = lastContentHash[pid]
        let contentChanged = (previousHash != nil && currentHash != previousHash)

        logToFile("Content analysis - length: \(content.count), changed: \(contentChanged), prevHash: \(previousHash ?? 0), currHash: \(currentHash)")

        lastContentHash[pid] = currentHash

        // RED - content is changing (output in progress) - check first
        if contentChanged {
            logToFile("State: RED (content changed)")
            return .red
        }

        // YELLOW patterns (waiting for user SELECTION)
        let hasNumberedOptions = (
            // Format: 1. ... 2. ... 3. ...
            (lastLines.contains("1.") && lastLines.contains("2.") && lastLines.contains("3.")) ||
            // Format: [1] ... [2] ...
            (lastLines.contains("[1]") && lastLines.contains("[2]")) ||
            // Format: [y/n]
            lastLines.contains("[y/n]") ||
            (lastLines.contains("[y]") && lastLines.contains("[n]")) ||
            // Format: ? (1-3) or ? [1-3]
            lastLines.range(of: "\\? \\(?\\[?1-\\d\\]?\\)?", options: .regularExpression) != nil ||
            // Format with question and numbered list
            (lastLines.contains("?") && lastLines.contains("1.") && lastLines.contains("2."))
        )

        if hasNumberedOptions {
            logToFile("State: YELLOW (numbered options)")
            return .yellow
        }

        // GREEN patterns (completed/ready)
        let greenPatterns = [
            "task completed",
            "任务完成",
            "已完成",
            "✓",
            "✅",
            "done!",
            "finished",
            "all done",
            "完成！",
            "worked for",
            "recap:",
            "what can i help",
            "有什么我可以帮助",
            "how can i help"
        ]

        for pattern in greenPatterns {
            if lastLines.contains(pattern) {
                return .green
            }
        }

        // Check last line for shell prompt (idle = GREEN)
        if let lastLine = lines.last {
            let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(">") || trimmed.hasSuffix("❯") || trimmed.hasSuffix("$") || trimmed.hasSuffix("%") {
                return .green
            }
        }

        // Default: if Claude process exists and content is stable, it's waiting for input (GREEN)
        // Not YELLOW - yellow is only for explicit selection prompts
        return .green
    }

    /// Find Claude process running in a terminal
    private func findClaudeProcessForTerminal(terminalPID: pid_t) -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(terminalPID)"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let childPIDs = output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { pid_t($0) }

            for childPID in childPIDs {
                if isClaudeProcess(childPID) {
                    return childPID
                }
                if let claudePID = findClaudeDescendant(childPID) {
                    return claudePID
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Recursively find Claude process among descendants
    private func findClaudeDescendant(_ pid: pid_t) -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let childPIDs = output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { pid_t($0) }

            for childPID in childPIDs {
                if isClaudeProcess(childPID) {
                    return childPID
                }
                if let found = findClaudeDescendant(childPID) {
                    return found
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Check if a process is Claude
    private func isClaudeProcess(_ pid: pid_t) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "comm="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }

            return output.trimmingCharacters(in: .whitespacesAndNewlines).contains("claude")
        } catch {
            return false
        }
    }
}
