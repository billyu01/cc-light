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

/// Snapshot of the process table: pid -> (ppid, comm).
private struct ProcSnapshot {
    var ppid: [pid_t: pid_t] = [:]
    var comm: [pid_t: String] = [:]
}

/// Detects terminal windows running Claude Code.
///
/// Performance note: the previous implementation forked `pgrep` / `ps` once
/// per pid per parent-walk step (potentially 30+ subprocesses per tick). On
/// macOS each subprocess is ~5-15 ms, so a single tick blocked the main
/// thread for hundreds of ms — that's why hovering the panel turned the
/// cursor into a beachball. We now take ONE `ps -Ao pid=,ppid=,comm=`
/// snapshot per tick and walk it entirely in Swift.
class WindowDetector {

    private let terminalNames: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "alacritty",
        "kitty", "warp", "hyper", "wezterm", "tabby"
    ]

    /// Find all terminal windows running Claude Code
    func detectClaudeWindows() -> [ClaudeWindow] {
        // 1. Single-shot read of the process table.
        let snap = readProcessSnapshot()

        // 2. Find Claude processes by command name (no -f match against full
        //    cmdline — too easy to false-positive on paths containing "claude").
        let claudePIDs = snap.comm.compactMap { (pid, comm) -> pid_t? in
            comm.lowercased() == "claude" ? pid : nil
        }
        guard !claudePIDs.isEmpty else { return [] }

        // 3. Walk up each Claude pid's ancestry in the snapshot to find a
        //    terminal app process.
        var terminalPIDs = Set<pid_t>()
        for cpid in claudePIDs {
            var cur: pid_t = cpid
            for _ in 0..<10 {
                guard let parent = snap.ppid[cur], parent > 0 else { break }
                if let comm = snap.comm[parent], isTerminalComm(comm) {
                    terminalPIDs.insert(parent)
                    break
                }
                cur = parent
            }
        }
        guard !terminalPIDs.isEmpty else { return [] }

        // 4. Match those terminal PIDs against on-screen windows.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var claudeWindows: [ClaudeWindow] = []
        for info in windowList {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let ownerName = info[kCGWindowOwnerName as String] as? String else { continue }

            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width > 100 && height > 100 else { continue }

            guard terminalPIDs.contains(pid) else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: width,
                height: height
            )
            claudeWindows.append(ClaudeWindow(
                windowID: windowID,
                processID: pid,
                windowTitle: title,
                appName: ownerName,
                frame: frame
            ))
        }

        return claudeWindows
    }

    // MARK: - Process snapshot

    /// One subprocess call, parsed in Swift. Replaces dozens of per-pid
    /// invocations from the old implementation.
    ///
    /// Subprocess plumbing notes (this got us deadlocked once):
    ///   - We MUST read stdout *before* calling waitUntilExit(). If ps writes
    ///     more than the pipe buffer (16-64 KB) and nothing is reading the
    ///     other end, ps blocks on write -> never exits -> waitUntilExit
    ///     blocks forever. With 4-5 hundred lines of `ps -A` we live close to
    ///     that limit.
    ///   - stderr goes to /dev/null. A Pipe() that's never read has the same
    ///     deadlock failure mode if ps prints anything to it (it can on
    ///     newer macOS versions).
    private func readProcessSnapshot() -> ProcSnapshot {
        var snap = ProcSnapshot()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,ppid=,comm="]

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try task.run()
        } catch {
            return snap
        }

        // Read first, then wait. readDataToEndOfFile blocks until ps closes
        // its stdout (i.e. until ps is done writing); ps then exits cleanly,
        // and the subsequent waitUntilExit returns immediately.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return snap }

        for line in output.split(separator: "\n") {
            // Format: "  PID  PPID COMM..." — comm may contain spaces / a path.
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }

            let commPath = String(parts[2])
            // comm is often a full path; we only need the basename.
            let comm = (commPath as NSString).lastPathComponent
            snap.ppid[pid] = ppid
            snap.comm[pid] = comm
        }

        return snap
    }

    private func isTerminalComm(_ comm: String) -> Bool {
        let c = comm.lowercased()
        // Strip common suffixes like ".app" or "Helper".
        for name in terminalNames {
            if c.contains(name) { return true }
        }
        return false
    }
}
