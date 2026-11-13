import AppKit
import ApplicationServices

/// Calls `onChange` (debounced) whenever something happens in Finder that might have
/// changed what a column-view window shows. Uses Accessibility notifications, plus a
/// slow poll as a safety net.
final class FinderWatcher {
    var onChange: () -> Void = {}

    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var debounce: Timer?
    private var poll: Timer?

    private static let notifications = [
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXSelectedChildrenChangedNotification,
        kAXSelectedRowsChangedNotification,
        kAXCreatedNotification,
        kAXTitleChangedNotification,
    ]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Finder.bundleID else { return }
                self?.attach()
                self?.scheduleCheck()
            }
        }
        attach()
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            if Finder.isFrontmost { self?.onChange() }
        }
    }

    func scheduleCheck(after delay: TimeInterval = 0.3) {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.onChange()
        }
    }

    /// (Re)subscribes to Finder's accessibility notifications; handles Finder relaunches.
    func attach() {
        guard AXIsProcessTrusted(), let finder = Finder.app else { return }
        let pid = finder.processIdentifier
        guard pid != observedPid || observer == nil else { return }

        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
        }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FinderWatcher>.fromOpaque(refcon).takeUnretainedValue().scheduleCheck()
        }
        var newObserver: AXObserver?
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else { return }

        let appElement = Finder.appElement(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(newObserver, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedPid = pid
    }
}
