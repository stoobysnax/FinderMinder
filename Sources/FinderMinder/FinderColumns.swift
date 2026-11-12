import AppKit
import ApplicationServices

enum Finder {
    static let bundleID = "com.apple.finder"

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    static func appElement(pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.5)
        return el
    }

    /// True while the user is renaming a file or typing in the search field.
    static func isEditingText(pid: pid_t) -> Bool {
        guard let focused = appElement(pid: pid).element(kAXFocusedUIElementAttribute) else { return false }
        let role = focused.role ?? ""
        return role == kAXTextFieldRole || role == kAXTextAreaRole
    }
}

/// One file-list column in a Finder column-view window.
struct FinderColumn {
    let element: AXUIElement   // the column's scroll area
    let list: AXUIElement      // the list/outline holding the file rows
    let frame: CGRect
}

/// Snapshot of the focused Finder window, if it is in column view.
struct FinderColumnView {
    let window: AXUIElement
    let browser: AXUIElement
    let browserFrame: CGRect
    let columns: [FinderColumn]   // left to right

    static let listRoles: Set<String> = [kAXListRole, kAXOutlineRole, kAXTableRole]

    static func focused(pid: pid_t) -> FinderColumnView? {
        let app = Finder.appElement(pid: pid)
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.elements(kAXWindowsAttribute).first,
              let browser = window.firstDescendant(maxDepth: 8, where: { $0.role == kAXBrowserRole }),
              let browserFrame = browser.frame else { return nil }

        var candidates = browser.elements(kAXColumnsAttribute)
        if candidates.isEmpty {
            candidates = browser.descendants(maxDepth: 4) { $0.role == kAXScrollAreaRole }
        }

        let columns = candidates.compactMap { el -> FinderColumn? in
            // Skip the preview column and wrappers: a real column directly holds a file list.
            guard let list = el.firstDescendant(maxDepth: 2, limit: 20, where: { listRoles.contains($0.role ?? "") }),
                  let frame = el.frame, frame.width > 1 else { return nil }
            return FinderColumn(element: el, list: list, frame: frame)
        }
        .sorted { $0.frame.minX < $1.frame.minX }

        guard !columns.isEmpty else { return nil }
        return FinderColumnView(window: window, browser: browser, browserFrame: browserFrame, columns: columns)
    }

    /// Describes what is shown (not how wide it is), so a change means "re-fit needed"
    /// while the user's own manual width tweaks are left alone.
    var signature: String {
        let title = window.string(kAXTitleAttribute) ?? ""
        let parts = columns.map { col -> String in
            let rows = col.list.children
            var selected = col.list.elements(kAXSelectedChildrenAttribute)
            if selected.isEmpty { selected = col.list.elements(kAXSelectedRowsAttribute) }
            return [
                String(rows.count),
                rows.first?.displayText ?? "",
                rows.last?.displayText ?? "",
                selected.map(\.displayText).joined(separator: ","),
            ].joined(separator: "\u{1}")
        }
        return title + "\u{2}" + parts.joined(separator: "\u{2}")
    }
}
