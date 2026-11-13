import AppKit
import ApplicationServices

/// Resizes Finder columns to fit their longest name.
///
/// It measures the names itself and then makes one drag of each column's resize grip
/// straight to the final width, so a column moves at most once and columns that are
/// already right don't move at all. Finder's own "right-size" double-click is used only
/// once, to learn where the grip is and how much space Finder leaves after a name.
final class ColumnFitter {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let calibrated = "GripCalibrated"
        static let dx = "GripOffsetX"
        static let dy = "GripOffsetY"
        static let extraWidth = "ExtraWidth"
        static let minimumWidth = "MinimumWidth"
        static let trailing = "TrailingPadding"
    }

    /// Space Finder leaves after the longest name in a right-sized column (chevron etc.).
    /// Learned once; this is only the fallback.
    static let defaultTrailing: Double = 28

    private var trailingPadding: Double? {
        defaults.object(forKey: Key.trailing) as? Double
    }

    private func learnTrailing(fittedWidth: CGFloat, content: CGFloat) {
        let t = Double(fittedWidth - content)
        guard (0...150).contains(t) else { return }
        defaults.set(t, forKey: Key.trailing)
        NSLog("FinderMinder: trailing padding \(t)")
    }

    /// Extra points added after Finder's tight fit, so badges after the name
    /// (e.g. Dropbox's sync check mark) aren't clipped.
    static let defaultExtraWidth: Double = 24

    /// "Wider" mode: columns never end up narrower than this.
    static let widerMinimum: Double = 250

    /// 0 means "Tight" (no minimum).
    var minimumWidth: Double {
        get { defaults.object(forKey: Key.minimumWidth) as? Double ?? 0 }
        set { defaults.set(newValue, forKey: Key.minimumWidth) }
    }

    var extraWidth: Double {
        get { defaults.object(forKey: Key.extraWidth) as? Double ?? Self.defaultExtraWidth }
        set { defaults.set(newValue, forKey: Key.extraWidth) }
    }

    /// Where the grip might be, relative to the bottom-right corner of a column.
    /// The first entry is the default; the first one that visibly resizes a column is remembered.
    static let candidates: [CGVector] = [
        CGVector(dx: -3, dy: -7),
        CGVector(dx: 0, dy: -7),
        CGVector(dx: 2, dy: -7),
        CGVector(dx: -6, dy: -7),
        CGVector(dx: -3, dy: -4),
        CGVector(dx: -3, dy: -11),
    ]

    private var calibratedOffset: CGVector? {
        guard defaults.bool(forKey: Key.calibrated) else { return nil }
        return CGVector(dx: defaults.double(forKey: Key.dx), dy: defaults.double(forKey: Key.dy))
    }

    func resetCalibration() {
        defaults.removeObject(forKey: Key.calibrated)
        defaults.removeObject(forKey: Key.dx)
        defaults.removeObject(forKey: Key.dy)
        defaults.removeObject(forKey: Key.trailing)
    }

    /// Returns false if it had to back off (e.g. the user is holding the mouse or a modifier key).
    @discardableResult
    func fit(_ view: FinderColumnView, pid: pid_t) -> Bool {
        guard NSEvent.pressedMouseButtons == 0 else { return false }
        let mods = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }

        let savedCursor = CGEvent(source: nil)?.location
        defer {
            if let savedCursor {
                CGWarpMouseCursorPosition(savedCursor)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        var triedCalibration = false
        // Right to left: resizing a column only shifts the columns to its right,
        // which have already been handled. Frames are re-read every time anyway.
        for column in view.columns.reversed() {
            if calibratedOffset == nil {
                guard !triedCalibration else { continue }
                triedCalibration = true
                calibrate(on: column, in: view, pid: pid)
            }
            guard let offset = calibratedOffset else { continue }

            let content = contentWidth(of: column)
            if trailingPadding == nil, let content,
               clickGrip(of: column, offset: offset, in: view, pid: pid) {
                // One time only: let Finder fit this column tightly to learn its spacing.
                usleep(150_000)
                if let w = column.element.frame?.width { learnTrailing(fittedWidth: w, content: content) }
            }
            resize(column, content: content, offset: offset, in: view, pid: pid)
            usleep(20_000)
        }
        return true
    }

    /// Distance from the column's left edge to the end of its longest name, measured
    /// in the font Finder is using. Nil for an empty column.
    private func contentWidth(of column: FinderColumn) -> CGFloat? {
        guard let colFrame = column.element.frame else { return nil }
        var rows = column.list.elements(kAXRowsAttribute)
        if rows.isEmpty { rows = column.list.children }

        let textRoles: Set<String> = [kAXTextFieldRole, kAXStaticTextRole]
        var font: NSFont?
        var textLeft: CGFloat?
        var widest: CGFloat = 0
        for row in rows.prefix(400) {
            guard let text = row.firstDescendant(maxDepth: 4, limit: 30, where: { textRoles.contains($0.role ?? "") }),
                  let name = text.string(kAXValueAttribute), !name.isEmpty else { continue }
            let f = font ?? Self.font(of: text)
            font = f
            if textLeft == nil, let tf = text.frame { textLeft = tf.minX - colFrame.minX }
            widest = max(widest, (name as NSString).size(withAttributes: [.font: f]).width)
        }
        guard let textLeft, widest > 0 else { return nil }
        return textLeft + ceil(widest)
    }

    /// The font of a file name in Finder's list, read through Accessibility.
    private static func font(of text: AXUIElement) -> NSFont {
        var range = CFRange(location: 0, length: 1)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                text, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &out) == .success,
               let attributed = out as? NSAttributedString, attributed.length > 0,
               let info = attributed.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
               let size = info["AXFontSize"] as? NSNumber {
                let pointSize = CGFloat(size.doubleValue)
                if let name = info["AXFontName"] as? String, let f = NSFont(name: name, size: pointSize) { return f }
                return NSFont.systemFont(ofSize: pointSize)
            }
        }
        // Fallback: estimate the size from the height of the text.
        let height = text.frame?.height ?? 16
        return NSFont.systemFont(ofSize: max(10, (height / 1.21).rounded()))
    }

    /// One drag of the grip straight to the final width; nothing if already close.
    private func resize(_ column: FinderColumn, content: CGFloat?, offset: CGVector,
                        in view: FinderColumnView, pid: pid_t) {
        guard let frame = column.element.frame else { return }
        var target = frame.width
        if let content {
            target = content + CGFloat(trailingPadding ?? Self.defaultTrailing) + CGFloat(extraWidth)
        }
        target = max(target, CGFloat(minimumWidth))
        let delta = target - frame.width
        guard abs(delta) >= 2 else { return }

        let start = CGPoint(x: frame.maxX + offset.dx, y: frame.maxY + offset.dy)
        guard view.browserFrame.insetBy(dx: 1, dy: 1).contains(start),
              isSafeTarget(start, browser: view.browser, pid: pid) else { return }
        drag(from: start, to: CGPoint(x: start.x + delta, y: start.y))
    }

    private func calibrate(on column: FinderColumn, in view: FinderColumnView, pid: pid_t) {
        for offset in Self.candidates {
            guard let before = column.element.frame,
                  clickGrip(of: column, offset: offset, in: view, pid: pid) else { continue }
            usleep(150_000)
            if let after = column.element.frame, abs(after.width - before.width) > 0.5 {
                defaults.set(true, forKey: Key.calibrated)
                defaults.set(Double(offset.dx), forKey: Key.dx)
                defaults.set(Double(offset.dy), forKey: Key.dy)
                NSLog("FinderMinder: grip found at offset (\(offset.dx), \(offset.dy))")
                if let content = contentWidth(of: column) {
                    learnTrailing(fittedWidth: after.width, content: content)
                }
                return
            }
        }
    }

    /// Double-clicks the column's grip if it is visible and the spot is verified safe.
    private func clickGrip(of column: FinderColumn, offset: CGVector, in view: FinderColumnView, pid: pid_t) -> Bool {
        guard let frame = column.element.frame else { return false }
        let point = CGPoint(x: frame.maxX + offset.dx, y: frame.maxY + offset.dy)
        guard view.browserFrame.insetBy(dx: 1, dy: 1).contains(point),
              isSafeTarget(point, browser: view.browser, pid: pid) else { return false }
        doubleClick(at: point)
        return true
    }

    /// Never double-click on something that could open a file or press a control:
    /// the spot must belong to Finder's column browser and must not be a row, icon, name,
    /// button or scroll bar.
    private func isSafeTarget(_ point: CGPoint, browser: AXUIElement, pid: pid_t) -> Bool {
        var hit: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit, hit.pid == pid else { return false }

        let forbidden: Set<String> = [
            kAXRowRole, kAXCellRole, kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole,
            kAXImageRole, kAXButtonRole, kAXCheckBoxRole, kAXMenuButtonRole, kAXPopUpButtonRole,
            kAXScrollBarRole, kAXValueIndicatorRole, "AXLink",
        ]
        var current: AXUIElement? = hit
        var depth = 0
        while let el = current, depth < 15 {
            if CFEqual(el, browser) { return true }
            let role = el.role ?? ""
            if forbidden.contains(role) { return false }
            // Anything *inside* a file list (rather than the list's empty background) is a file.
            if depth > 0 && FinderColumnView.listRoles.contains(role) { return false }
            current = el.parent
            depth += 1
        }
        return false
    }

    private func drag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: p, mouseButton: .left) else { return }
            e.flags = []
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start)
        usleep(15_000)
        post(.leftMouseDown, start)
        usleep(15_000)
        let steps = 6
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y))
            usleep(8_000)
        }
        post(.leftMouseUp, end)
    }

    private func doubleClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, clickState: Int64) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
            e.flags = []
            e.setIntegerValueField(.mouseEventClickState, value: clickState)
            e.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, clickState: 0)
        usleep(15_000)
        post(.leftMouseDown, clickState: 1)
        post(.leftMouseUp, clickState: 1)
        usleep(10_000)
        post(.leftMouseDown, clickState: 2)
        post(.leftMouseUp, clickState: 2)
    }
}
