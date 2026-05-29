import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.trafficlight.app", category: "detector")

/// Represents a terminal window running Claude Code
struct ClaudeWindow: Hashable {
    let windowID: CGWindowID
    let processID: pid_t
    let windowTitle: String
    let appName: String
    let frame: CGRect

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(processID)
    }

    static func == (lhs: ClaudeWindow, rhs: ClaudeWindow) -> Bool {
        lhs.windowID == rhs.windowID && lhs.processID == rhs.processID
    }
}

/// Detects terminal windows running Claude Code
class WindowDetector {

    /// Find all terminal windows running Claude Code
    func detectClaudeWindows() -> [ClaudeWindow] {
        var claudeWindows: [ClaudeWindow] = []

        // Get Claude process IDs
        let claudePIDs = getClaudeProcessIDs()
        guard !claudePIDs.isEmpty else { return [] }

        // Get parent terminal process IDs
        let terminalPIDs = getParentTerminalPIDs(for: claudePIDs)

        // Get all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let ownerName = windowInfo[kCGWindowOwnerName as String] as? String else {
                continue
            }

            // Skip windows with zero size
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width > 100 && height > 100 else { continue }

            // Check if this window belongs to a terminal app running Claude
            if terminalPIDs.contains(pid) {
                let title = windowInfo[kCGWindowName as String] as? String ?? ""
                let frame = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: width,
                    height: height
                )

                let window = ClaudeWindow(
                    windowID: windowID,
                    processID: pid,
                    windowTitle: title,
                    appName: ownerName,
                    frame: frame
                )
                claudeWindows.append(window)
            }
        }

        return claudeWindows
    }

    /// Get all Claude Code process IDs
    private func getClaudeProcessIDs() -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "claude"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { pid_t($0) }
        } catch {
            return []
        }
    }

    /// Get parent terminal process IDs for Claude processes
    private func getParentTerminalPIDs(for claudePIDs: [pid_t]) -> Set<pid_t> {
        var terminalPIDs = Set<pid_t>()

        for claudePID in claudePIDs {
            // Traverse up the process tree to find terminal
            var currentPID: pid_t? = claudePID
            var depth = 0
            while let pid = currentPID, depth < 10 {
                if let parentPID = getParentPID(for: pid) {
                    // Check if parent is a terminal app
                    if isTerminalProcess(parentPID) {
                        terminalPIDs.insert(parentPID)
                    }
                    currentPID = parentPID
                    depth += 1
                } else {
                    break
                }
            }
        }

        return terminalPIDs
    }

    /// Check if a process is a terminal application
    private func isTerminalProcess(_ pid: pid_t) -> Bool {
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

            let comm = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let terminalNames = ["terminal", "iterm", "ghostty", "alacritty", "kitty", "warp", "hyper"]
            return terminalNames.contains { comm.contains($0) }
        } catch {
            return false
        }
    }

    /// Get parent process ID
    private func getParentPID(for pid: pid_t) -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "ppid="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)).map { pid_t($0) }
        } catch {
            return nil
        }
    }

    /// Check if a terminal process is running Claude
    private func isTerminalRunningClaude(pid: pid_t, claudePIDs: [pid_t]) -> Bool {
        // Get all child processes of this terminal
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }

            let childPIDs = output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { pid_t($0) }

            // Check if any child or descendant is a Claude process
            for childPID in childPIDs {
                if claudePIDs.contains(childPID) {
                    return true
                }
                // Recursively check descendants
                if hasClaudeDescendant(pid: childPID, claudePIDs: claudePIDs) {
                    return true
                }
            }
        } catch {}

        return false
    }

    /// Recursively check if any descendant is a Claude process
    private func hasClaudeDescendant(pid: pid_t, claudePIDs: [pid_t]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }

            let childPIDs = output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { pid_t($0) }

            for childPID in childPIDs {
                if claudePIDs.contains(childPID) {
                    return true
                }
                if hasClaudeDescendant(pid: childPID, claudePIDs: claudePIDs) {
                    return true
                }
            }
        } catch {}

        return false
    }
}
