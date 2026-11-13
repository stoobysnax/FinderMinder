import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = FinderWatcher()
    private let fitter = ColumnFitter()
    private var lastSignature = ""
    private var trustTimer: Timer?

    private let defaults = UserDefaults.standard
    private var autoFit: Bool {
        get { defaults.object(forKey: "AutoFit") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "AutoFit") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "FinderMinder")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.onChange = { [weak self] in self?.check(force: false) }

        if AXIsProcessTrusted() {
            watcher.start()
        } else {
            requestAccessibility()
        }
    }

    // MARK: - Accessibility permission

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.watcher.start()
        }
    }

    // MARK: - Fitting

    private func check(force: Bool) {
        guard AXIsProcessTrusted(), autoFit || force, Finder.isFrontmost,
              let pid = Finder.app?.processIdentifier,
              !Finder.isEditingText(pid: pid),
              let view = FinderColumnView.focused(pid: pid) else { return }

        let signature = view.signature
        guard force || signature != lastSignature else { return }

        if fitter.fit(view, pid: pid) {
            lastSignature = FinderColumnView.focused(pid: pid)?.signature ?? signature
        } else {
            // Mouse or modifier key was held; try again shortly.
            watcher.scheduleCheck(after: 0.5)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "FinderMinder", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(grantAccess)))
            let note = NSMenuItem(title: "Needed to read and resize Finder columns", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        let auto = item("Auto-Fit Column Widths", #selector(toggleAutoFit))
        auto.state = autoFit ? .on : .off
        menu.addItem(auto)
        menu.addItem(item("Fit Columns Now", #selector(fitNow)))

        let extraMenu = NSMenu()
        for points in [0, 12, 24, 36, 48, 64] {
            let title = points == 0 ? "None (tight fit)" : "\(points) points"
            let i = item(title, #selector(setExtraWidth(_:)))
            i.tag = points
            i.state = Int(fitter.extraWidth) == points ? .on : .off
            extraMenu.addItem(i)
        }
        let extra = NSMenuItem(title: "Extra Width", action: nil, keyEquivalent: "")
        extra.submenu = extraMenu
        menu.addItem(extra)

        let minMenu = NSMenu()
        for (title, points) in [("Tight", 0.0), ("Wider", ColumnFitter.widerMinimum)] {
            let i = item(title, #selector(setMinimumWidth(_:)))
            i.tag = Int(points)
            i.state = fitter.minimumWidth == points ? .on : .off
            minMenu.addItem(i)
        }
        let minItem = NSMenuItem(title: "Minimum Width", action: nil, keyEquivalent: "")
        minItem.submenu = minMenu
        menu.addItem(minItem)

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Reset Grip Calibration", #selector(resetCalibration)))
        menu.addItem(item("Copy Diagnostics", #selector(copyDiagnostics)))

        menu.addItem(.separator())
        menu.addItem(item("Quit FinderMinder", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func grantAccess() {
        requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleAutoFit() {
        autoFit.toggle()
        lastSignature = ""
        if autoFit { watcher.scheduleCheck() }
    }

    @objc private func fitNow() {
        // Give the menu time to close and Finder to be frontmost again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if !Finder.isFrontmost { Finder.app?.activate(options: []) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.check(force: true) }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure FinderMinder.app is in your Applications folder."
            alert.runModal()
        }
    }

    @objc private func setExtraWidth(_ sender: NSMenuItem) {
        fitter.extraWidth = Double(sender.tag)
        lastSignature = ""
        watcher.scheduleCheck()
    }

    @objc private func setMinimumWidth(_ sender: NSMenuItem) {
        fitter.minimumWidth = Double(sender.tag)
        lastSignature = ""
        watcher.scheduleCheck()
    }

    @objc private func resetCalibration() {
        fitter.resetCalibration()
        lastSignature = ""
    }

    @objc private func copyDiagnostics() {
        let text = Diagnostics.report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
