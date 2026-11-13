import AppKit
import ApplicationServices

/// Resizes Finder columns by double-clicking each column's resize grip — the same
/// thing you'd do by hand — which makes Finder size the column to its longest name.
final class ColumnFitter {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let calibrated = "GripCalibrated"
        static let dx = "GripOffsetX"
        static let dy = "GripOffsetY"
        static let extraWidth = "ExtraWidth"
        static let minimumWidth = "MinimumWidth"
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
            var fitted = false
            if let offset = calibratedOffset {
                fitted = clickGrip(of: column, offset: offset, in: view, pid: pid)
            } else if !triedCalibration {
                triedCalibration = true
                calibrate(on: column, in: view, pid: pid)
                fitted = calibratedOffset != nil
            } else {
                _ = clickGrip(of: column, offset: Self.candidates[0], in: view, pid: pid)
            }
            if fitted, let offset = calibratedOffset {
                usleep(60_000)
                widen(column, offset: offset, in: view, pid: pid)
            }
            usleep(30_000)
        }
        return true
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

    /// Drags the column's grip to the right, after Finder's tight fit.
    /// Grows a just-fitted column to (fitted width + extra width), or to the minimum
    /// width if that is larger, by dragging its grip to the right.
    private func widen(_ column: FinderColumn, offset: CGVector,
                       in view: FinderColumnView, pid: pid_t) {
        guard let frame = column.element.frame else { return }
        let target = max(frame.width + extraWidth, minimumWidth)
        let extra = target - frame.width
        guard extra > 0.5 else { return }
        let start = CGPoint(x: frame.maxX + offset.dx, y: frame.maxY + offset.dy)
        guard view.browserFrame.insetBy(dx: 1, dy: 1).contains(start),
              isSafeTarget(start, browser: view.browser, pid: pid) else { return }
        drag(from: start, to: CGPoint(x: start.x + extra, y: start.y))
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
