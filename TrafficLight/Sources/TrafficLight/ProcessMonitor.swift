import Foundation
import Cocoa
import ApplicationServices
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
    case red      // Claude is outputting
    case yellow   // Waiting for user selection
    case green    // Idle / completed
}

/// Per-window tracking state. Keyed by (pid, windowID) so multiple terminals
/// belonging to the same app no longer trample each other.
private struct WindowKey: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

private struct WindowTrack {
    var lastOutputHash: Int = 0
    var lastChangeAt: Date = .distantPast
    var lastState: TrafficLightState = .green
}

/// Monitors Claude Code terminal output via Accessibility API
class ProcessMonitor {
    private var tracks: [WindowKey: WindowTrack] = [:]

    /// How long after the last detected output change we keep the light RED.
    /// This swallows the spinner's "tick / no-tick" jitter and any single-poll
    /// gaps where the AX text happens to be identical between two reads.
    private let redHoldInterval: TimeInterval = 1.5

    /// Get the current state for a Claude window.
    func getState(for window: ClaudeWindow) -> TrafficLightState {
        let key = WindowKey(pid: window.processID, windowID: window.windowID)
        var track = tracks[key] ?? WindowTrack()

        // 1. Pull terminal text for THIS specific window.
        guard let rawContent = getTerminalContent(for: window) else {
            logToFile("[\(window.windowID)] no AX content; keeping last state \(track.lastState)")
            return track.lastState
        }

        // 2. Strip the input-box region and the animated spinner/timer.
        //    Only the "output region" should drive RED.
        let outputRegion = stripInputBox(from: rawContent)
        let normalized = normalizeForHash(outputRegion)

        // 3. Decide state with correct priority: YELLOW > RED > GREEN.
        let state = decideState(
            outputRegion: outputRegion,
            normalizedOutput: normalized,
            track: &track,
            windowID: window.windowID
        )

        track.lastState = state
        tracks[key] = track
        return state
    }

    /// Forget windows that no longer exist so the dictionary doesn't leak.
    func prune(activeWindows: [ClaudeWindow]) {
        let keep = Set(activeWindows.map { WindowKey(pid: $0.processID, windowID: $0.windowID) })
        tracks = tracks.filter { keep.contains($0.key) }
    }

    // MARK: - State machine

    private func decideState(
        outputRegion: String,
        normalizedOutput: String,
        track: inout WindowTrack,
        windowID: CGWindowID
    ) -> TrafficLightState {
        let now = Date()

        // YELLOW first: explicit selection prompts. Highest priority — even if
        // the spinner is still ticking, if the user is being asked to pick, the
        // light should call that out.
        if looksLikeSelectionPrompt(outputRegion) {
            logToFile("[\(windowID)] YELLOW (selection prompt)")
            return .yellow
        }

        // RED: the OUTPUT region's normalized hash actually changed, OR we are
        // still inside the red-hold window after a recent change. Hold avoids
        // the 1Hz green/red strobe caused by the spinner alternating frames.
        let currentHash = normalizedOutput.hashValue
        let changed = (track.lastOutputHash != 0) && (currentHash != track.lastOutputHash)
        if track.lastOutputHash == 0 {
            // First sample: seed without flagging a change.
            track.lastOutputHash = currentHash
        }
        if changed {
            track.lastChangeAt = now
            track.lastOutputHash = currentHash
            logToFile("[\(windowID)] RED (output changed)")
            return .red
        }
        if now.timeIntervalSince(track.lastChangeAt) < redHoldInterval {
            logToFile("[\(windowID)] RED (hold, \(String(format: "%.2f", now.timeIntervalSince(track.lastChangeAt)))s since last change)")
            return .red
        }

        // GREEN: nothing changed for a while.
        return .green
    }

    private func looksLikeSelectionPrompt(_ text: String) -> Bool {
        // Claude Code's actual selection menu lives in the last few lines just
        // above the input box. Looking 40 lines deep was too greedy — it
        // false-positively matched any document or chat message that happens
        // to contain "1." "2." "3.", which then *locked* the light on YELLOW
        // because YELLOW outranks RED.
        //
        // Tighten the rule:
        //   - only inspect the last 12 lines
        //   - require LINE-START matches (after optional leading whitespace
        //     and an optional bullet glyph "❯" / ">"), not substring hits
        //   - require numbered items 1 and 2 to be on adjacent-ish lines
        //   - drop the "do you want ... yes ... no" heuristic; it triggers on
        //     ordinary prose
        let lines = text.components(separatedBy: "\n")
        let tail = Array(lines.suffix(12))
        let lower = tail.map { $0.lowercased() }

        // Yes/no prompts that Claude Code actually renders.
        let joined = lower.joined(separator: "\n")
        if joined.contains("[y/n]") { return true }
        if joined.contains("(y/n)") { return true }
        if joined.contains("(y/n/a)") { return true }

        // Numbered menu: lines like "  ❯ 1. foo" or "1) foo" or "[1] foo".
        // Pattern: optional leading whitespace, optional cursor glyph, then
        // the digit, then "." or ")" or "]" — followed by a space and text.
        let itemRe = try? NSRegularExpression(
            pattern: #"^\s*(?:[❯>*]\s*)?(?:\[(\d+)\]|(\d+)[.)])\s+\S"#
        )
        guard let re = itemRe else { return false }

        var firstItemLine: Int? = nil
        var secondItemLine: Int? = nil
        for (i, raw) in tail.enumerated() {
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: raw, range: range) else { continue }
            // Extract the digit from whichever group matched.
            let g1 = m.range(at: 1), g2 = m.range(at: 2)
            let digitStr: String
            if g1.location != NSNotFound {
                digitStr = ns.substring(with: g1)
            } else if g2.location != NSNotFound {
                digitStr = ns.substring(with: g2)
            } else { continue }
            guard let n = Int(digitStr) else { continue }
            if n == 1 { firstItemLine = i }
            if n == 2 { secondItemLine = i }
        }

        // Both "1" and "2" must appear, on lines close together (an actual
        // menu, not coincidental numbered prose scattered around).
        if let a = firstItemLine, let b = secondItemLine, abs(a - b) <= 3 {
            // Diagnostic: log the actual lines that triggered the match so
            // we can tell real menus from prose false-positives.
            logToFile("YELLOW match: line[\(a)]=\(repr(tail[a])) line[\(b)]=\(repr(tail[b]))")
            return true
        }
        return false
    }

    /// Show invisible characters so we can see what AX really gave us.
    private func repr(_ s: String) -> String {
        let truncated = s.count > 120 ? String(s.prefix(120)) + "…" : s
        return "\"" + truncated
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
            + "\""
    }

    // MARK: - Content cleaning

    /// Drop the bottom "input box" region. Claude Code's TUI draws the input
    /// area with box-drawing borders (╭ ─ ╮ │ ╰ ╯). User keystrokes only
    /// mutate text *inside* that region, so excluding it makes typing
    /// invisible to the hash — which is exactly what we want.
    private func stripInputBox(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        // Walk from the bottom up; once we find a line that contains a
        // box-drawing character, treat everything from there on as input chrome.
        let boxChars: Set<Character> = ["╭", "╮", "╯", "╰", "─", "│", "┌", "┐", "└", "┘", "━", "┃"]
        var cutoff = lines.count
        for i in stride(from: lines.count - 1, through: max(0, lines.count - 8), by: -1) {
            let line = lines[i]
            if line.contains(where: { boxChars.contains($0) }) {
                cutoff = i
            }
        }
        if cutoff < lines.count {
            return lines.prefix(cutoff).joined(separator: "\n")
        }
        return content
    }

    /// Strip animated bits that change every frame even when Claude is idle on
    /// the spinner: braille spinner glyphs, the "(Ns · esc to interrupt)"
    /// counter, and stray ANSI escape sequences.
    private func normalizeForHash(_ text: String) -> String {
        var out = text

        // ANSI CSI sequences (e.g. cursor moves, color resets).
        out = out.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )

        // Braille spinner frames used by Claude Code and most TUI tools.
        out = out.replacingOccurrences(
            of: "[\u{2800}-\u{28FF}]",
            with: "",
            options: .regularExpression
        )

        // Other common spinner glyphs.
        out = out.replacingOccurrences(
            of: "[◐◓◑◒◴◷◶◵⣾⣽⣻⢿⡿⣟⣯⣷]",
            with: "",
            options: .regularExpression
        )

        // The elapsed-seconds counter Claude prints next to the spinner, e.g.
        // "(12s · esc to interrupt)" or "(1m 4s · esc to interrupt)".
        out = out.replacingOccurrences(
            of: "\\((?:\\d+m\\s*)?\\d+s[^)]*\\)",
            with: "",
            options: .regularExpression
        )

        // "esc to interrupt" can also appear bare.
        out = out.replacingOccurrences(of: "esc to interrupt", with: "")

        // Token counters like "1.2k tokens" sometimes tick during streaming —
        // collapse digit runs so that only structural changes matter.
        out = out.replacingOccurrences(
            of: "\\d+",
            with: "#",
            options: .regularExpression
        )

        return out
    }

    // MARK: - AX text extraction

    /// Get terminal content for the specific window we care about.
    /// Critically: when one terminal app hosts multiple windows (the common
    /// case with iTerm2), `kAXWindowsAttribute` returns ALL of them. We must
    /// pick the one whose on-screen frame matches `window.frame`, otherwise
    /// the two traffic lights end up reading the same text.
    private func getTerminalContent(for window: ClaudeWindow) -> String? {
        let appRef = AXUIElementCreateApplication(window.processID)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windowList = windowsRef as? [AXUIElement] else {
            return nil
        }

        // Try to match by frame first.
        if let matched = matchAXWindow(in: windowList, to: window.frame) {
            return extractTextFromElement(matched)
        }

        // Fallback: only one window — must be it.
        if windowList.count == 1 {
            return extractTextFromElement(windowList[0])
        }

        // Last-resort fallback: the focused window.
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() {
            return extractTextFromElement(el as! AXUIElement)
        }

        return nil
    }

    /// Pick the AX window whose position+size best matches the CGWindow frame.
    private func matchAXWindow(in windows: [AXUIElement], to target: CGRect) -> AXUIElement? {
        var best: (AXUIElement, CGFloat)? = nil
        for w in windows {
            guard let frame = axFrame(of: w) else { continue }
            let dx = frame.origin.x - target.origin.x
            let dy = frame.origin.y - target.origin.y
            let dw = frame.size.width - target.size.width
            let dh = frame.size.height - target.size.height
            let dist = dx * dx + dy * dy + dw * dw + dh * dh
            if best == nil || dist < best!.1 {
                best = (w, dist)
            }
        }
        // Require a reasonably tight match (within ~50px on each axis combined).
        if let (w, d) = best, d < 10000 {
            return w
        }
        return best?.0
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pos = posRef, let sz = sizeRef else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(sz as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: size)
    }

    /// Recursively extract text from AXUIElement
    private func extractTextFromElement(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if let text = value as? String, text.count > 50 {
            return text
        }

        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard let childList = children as? [AXUIElement] else { return nil }

        for child in childList {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            if let r = role as? String,
               r == "AXTextArea" || r == "AXStaticText" || r == "AXWebArea" {
                var childValue: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &childValue)
                if let text = childValue as? String, text.count > 50 {
                    return text
                }
            }
            if let text = extractTextFromElement(child) {
                return text
            }
        }
        return nil
    }
}
