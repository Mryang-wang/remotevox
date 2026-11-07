import AppKit
import ApplicationServices
import IOKit

final class T1SystemNavigation {
    private enum Mode { case apps, switcher }

    private static let eventTag: Int64 = 0x54314E4156
    private var mode: Mode?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var timer: Timer?
    private var overlay: CGWindowID?
    private var previousDockWindows = Set<CGWindowID>()
    private var deadline = 0.0
    private var capturedOK = false
    private var capturedBack = false
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    var isActive: Bool { mode != nil }

    func showApps() {
        if mode == .apps, overlay != nil, findOverlay(.apps) == overlay {
            close()
            return
        }
        close()
        guard NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Apps.app")) else {
            log("T1 无法打开系统 App 菜单")
            return
        }
        if start(.apps) { log("T1 已请求打开系统 App 菜单") }
    }

    func showSwitcher() {
        if mode == .switcher {
            close()
            return
        }
        close()
        previousDockWindows = Set(dockWindows())
        guard start(.switcher) else { return }
        send(55, down: true, flags: .maskCommand, modifier: true)
        press(48, flags: .maskCommand)
    }

    func showDesktop() {
        close()
        press(4, flags: .maskSecondaryFn)
    }

    func close() {
        end(cancel: true)
    }

    @discardableResult
    func backPressed() -> Bool {
        guard mode != nil else { return false }
        close()
        log("T1 返回键：关闭系统 App 菜单或切换器")
        return true
    }

    private func end(cancel: Bool) {
        let oldMode = mode
        let shouldDismissApps = cancel && oldMode == .apps && overlay != nil && findOverlay(.apps) == overlay
        let shouldCancelSwitch = cancel && oldMode == .switcher && (overlay == nil || findOverlay(.switcher) == overlay)
        mode = nil
        overlay = nil
        capturedOK = false
        capturedBack = false
        timer?.invalidate()
        timer = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil

        switch oldMode {
        case .switcher:
            if shouldCancelSwitch { press(53, flags: .maskCommand) }
            send(55, down: false, modifier: true)
        case .apps:
            // Escape steps back from Apps into Spotlight. Fn-Shift-A hides the panel.
            if shouldDismissApps { press(0, flags: [.maskSecondaryFn, .maskShift]) }
        case nil: break
        }
    }

    private func start(_ mode: Mode) -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let navigation = Unmanaged<T1SystemNavigation>.fromOpaque(context).takeUnretainedValue()
                return navigation.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            log("T1 无法监听系统菜单的 OK 键")
            return false
        }
        self.mode = mode
        deadline = ProcessInfo.processInfo.systemUptime + 2
        tap = port
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.checkOverlay() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    private func checkOverlay() {
        guard let mode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let current = findOverlay(mode)
        if let current, overlay == nil {
            overlay = current
            deadline = now + 10
            log(mode == .apps ? "T1 系统 App 菜单已显示" : "T1 系统 App 切换器已显示")
        } else if overlay != nil && current != overlay {
            end(cancel: false)
        } else if (overlay == nil || mode == .switcher) && now >= deadline {
            end(cancel: true)
        }
    }

    private func findOverlay(_ mode: Mode) -> CGWindowID? {
        if mode == .switcher { return dockWindows().first { !previousDockWindows.contains($0) } }
        // On macOS 27 the Spotlight Apps window is hosted by Siri. A closed
        // Apps window may leave the short Spotlight search field on screen.
        return systemWindows(owners: ["com.apple.campo", "com.apple.Siri", "com.apple.Spotlight"]).first {
            ($0[kCGWindowLayer as String] as? Int) == 23 &&
            (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) >= 200 &&
            self.hasFocusedWindow($0[kCGWindowOwnerPID as String] as? pid_t)
        }?[kCGWindowNumber as String] as? CGWindowID
    }

    private func hasFocusedWindow(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        var window: CFTypeRef?
        return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
            kAXFocusedWindowAttribute as CFString, &window) == .success && window != nil
    }

    private func dockWindows() -> [CGWindowID] {
        systemWindows(owners: ["com.apple.dock"]).compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    private func systemWindows(owners: [String]) -> [[String: Any]] {
        let pids = owners.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .map(\.processIdentifier)
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return pids.contains(pid)
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard let mode else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            close()
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return false }

        // These F16–F20 events are T1's remapped front buttons. The HID
        // controller already handles them before they reach this event tap.
        if (type == .keyDown || type == .keyUp),
           [106, 64, 79, 80, 90, 105].contains(event.getIntegerValueField(.keyboardEventKeycode)) {
            return true
        }

        if mode == .switcher {
            if type == .flagsChanged { close(); return false }
            if type == .keyDown || type == .keyUp {
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                switch key {
                case 48, 123, 124, 125, 126:
                    event.flags.insert(.maskCommand)
                    if key == 125 { event.setIntegerValueField(.keyboardEventKeycode, value: 124) }
                    if key == 126 { event.setIntegerValueField(.keyboardEventKeycode, value: 123) }
                    deadline = ProcessInfo.processInfo.systemUptime + 10
                    return false
                case 36, 76, 53:
                    if type == .keyDown {
                        DispatchQueue.main.async { [weak self] in self?.end(cancel: key == 53) }
                    }
                    return true
                default:
                    if type == .keyDown { close() }
                    return false
                }
            }
        }

        switch type {
        case .rightMouseDown:
            guard let overlay, isT1(event), findOverlay(mode) == overlay else { return false }
            capturedBack = true
            return true
        case .rightMouseUp where capturedBack && isT1(event):
            capturedBack = false
            DispatchQueue.main.async { [weak self] in self?.backPressed() }
            return true
        case .rightMouseDragged where capturedBack && isT1(event): return true
        case .leftMouseDown:
            guard let overlay, isT1(event), findOverlay(mode) == overlay else { return false }
            capturedOK = true
            return true
        case .leftMouseUp where capturedOK && isT1(event):
            capturedOK = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mode == mode else { return }
                let target = mode == .apps ? self.appsPID() : nil
                self.end(cancel: false)
                if let target { self.press(36, to: target) }
            }
            return true
        case .leftMouseDragged where capturedOK && isT1(event): return true
        default: return false
        }
    }

    private func appsPID() -> pid_t? {
        guard mode == .apps, let overlay, findOverlay(.apps) == overlay else { return nil }
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, overlay) as? [[String: Any]] ?? []
        return windows.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    private func press(_ code: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t? = nil) {
        send(code, down: true, flags: flags, to: pid)
        send(code, down: false, flags: flags, to: pid)
    }

    private func send(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], modifier: Bool = false, to pid: pid_t? = nil) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState),
                                  virtualKey: code, keyDown: down) else { return }
        if modifier { event.type = .flagsChanged }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    }

    private func isT1(_ event: CGEvent) -> Bool {
        T1DeviceEvent.isT1(event)
    }
}
