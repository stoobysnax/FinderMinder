import AppKit
import ApplicationServices

/// Text dump of what FinderMinder sees in the frontmost Finder window — handy if
/// columns aren't being resized on some macOS version.
enum Diagnostics {
    static func report() -> String {
        var out = "FinderMinder diagnostics\n"
        out += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Accessibility trusted: \(AXIsProcessTrusted())\n"
        let d = UserDefaults.standard
        out += "Grip calibrated: \(d.bool(forKey: "GripCalibrated")) offset: (\(d.double(forKey: "GripOffsetX")), \(d.double(forKey: "GripOffsetY")))\n"

        guard let pid = Finder.app?.processIdentifier else { return out + "Finder not running\n" }
        let app = Finder.appElement(pid: pid)
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.elements(kAXWindowsAttribute).first else {
            return out + "No Finder window\n"
        }

        if let view = FinderColumnView.focused(pid: pid) {
            out += "Column view: \(view.columns.count) columns, browser frame \(view.browserFrame)\n"
            out += "Browser attributes: \(view.browser.attributeNames.joined(separator: ", "))\n"
            for (i, c) in view.columns.enumerated() {
                out += "  column \(i): \(c.frame) rows: \(c.list.children.count)\n"
            }
        } else {
            out += "Focused window is not in column view (no AXBrowser found)\n"
        }

        out += "\nAccessibility tree:\n"
        dump(window, depth: 0, into: &out)
        return out
    }

    private static func dump(_ el: AXUIElement, depth: Int, into out: inout String) {
        guard depth <= 12 else { return }
        let indent = String(repeating: "  ", count: depth)
        var line = indent + (el.role ?? "?")
        if let sub = el.subrole { line += " [\(sub)]" }
        let text = el.string(kAXTitleAttribute) ?? el.string(kAXValueAttribute) ?? ""
        if !text.isEmpty { line += " \"\(text.prefix(60))\"" }
        if let f = el.frame { line += " \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))" }
        out += line + "\n"

        let kids = el.children
        // Don't descend into every file row; a few are enough to see the structure.
        let isList = FinderColumnView.listRoles.contains(el.role ?? "")
        let shown = isList ? Array(kids.prefix(3)) : Array(kids.prefix(40))
        for k in shown { dump(k, depth: depth + 1, into: &out) }
        if kids.count > shown.count { out += indent + "  … \(kids.count - shown.count) more\n" }
    }
}
