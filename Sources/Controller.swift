import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

final class T1Controller {
    private struct ButtonPress {
        let pid: pid_t
        let single: T1Binding
        let double: T1Binding
        var click: DispatchWorkItem?
        var hold: DispatchWorkItem?
    }

    private let profiles: T1ProfileStore
    private var profileObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var mouseBackCaptured = false
    private var capturedNavigation = Set<T1Button>()
    private var searchCloseCache: (pid: pid_t, window: AXUIElement, button: AXUIElement)?
    private let searchCloseLabels: Set<String> = ["关闭查找", "關閉尋找", "close find", "close search", "关闭搜索"]
    private let mappingQueue = DispatchQueue(label: "local.codex.t1.mapping")
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var bluetoothDevices = Set<IOHIDDevice>()
    private var receiverDevices = Set<IOHIDDevice>()
    private var connectionMode = T1ConnectionMode.automatic
    private(set) var receiverActive = false
    var receiverAttached: Bool { !receiverDevices.isEmpty }
    var transport: T1Transport {
        if connectionMode == .receiver || (connectionMode == .automatic && bluetoothDevices.isEmpty && receiverAttached) {
            return .receiver
        }
        return .bluetooth
    }
    private var listening = false
    var hasHIDInput: Bool { listening }
    private var chatActionGeneration = 0
    private lazy var systemNavigation = T1SystemNavigation(log: log, acceptsT1: { [weak self] event in
        guard let self else { return false }
        return T1DeviceEvent.transport(event) == self.transport
    })
    private var keys = Set<UInt32>()
    private var buttonPresses: [T1Button: ButtonPress] = [:]
    private var voiceClick: DispatchWorkItem?
    private var powerClick: DispatchWorkItem?
    private var powerHold: DispatchWorkItem?
    private var longFired = false
    private var shutdownWindow: NSWindow?
    private var shutdownClickCaptured = false
    private var voiceTarget: pid_t?
    private var voiceWindow: AXUIElement?
    private var voiceStarted = 0.0
    private var idleVoiceChecks = 0
    private var voiceGeneration = 0
    private var nativeStartRequested = false
    private var controllerOpenedMic = false
    private let audioReady: () -> Bool
    private let openMic: () -> Bool
    private let closeMic: () -> Void
    private let log: (String) -> Void
    private let trace: (String) -> Void
    private let handlesVoiceKey: () -> Bool
    private let localVoiceKey: () -> Void
    private let cancelLocalVoice: () -> Void
    private let connectionChanged: () -> Void
    private let receiverVoiceKey: () -> Bool
    private let appID = T1ButtonAction.codexAppID
    private let replyStopLabels: Set<String> = ["stop", "停止", "stop generating", "停止生成"]
    private let replyResumeLabels: Set<String> = ["resume", "继续", "繼續", "恢復"]
    private let startLabels: Set<String> = ["dictate", "听写", "聽寫"]
    private let stopLabels: Set<String> = ["stop dictation", "finish dictation", "停止听写", "结束听写", "停止聽寫", "結束聽寫", "停止口述"]
    private let cancelLabels: Set<String> = ["cancel dictation", "取消听写", "取消聽寫", "starting dictation; click to cancel", "正在启动听写；点击可取消", "正在開始聽寫；按一下即可取消"]

    init(openMic: @escaping () -> Bool, audioReady: @escaping () -> Bool, closeMic: @escaping () -> Void,
         handlesVoiceKey: @escaping () -> Bool, log: @escaping (String) -> Void,
         trace: @escaping (String) -> Void = { _ in },
         profiles: T1ProfileStore = .shared, localVoiceKey: @escaping () -> Void = {},
         cancelLocalVoice: @escaping () -> Void = {}, connectionChanged: @escaping () -> Void = {},
         receiverVoiceKey: @escaping () -> Bool = { false }) {
        self.openMic = openMic
        self.audioReady = audioReady
        self.closeMic = closeMic
        self.handlesVoiceKey = handlesVoiceKey
        self.localVoiceKey = localVoiceKey
        self.cancelLocalVoice = cancelLocalVoice
        self.connectionChanged = connectionChanged
        self.receiverVoiceKey = receiverVoiceKey
        self.log = log
        self.trace = trace
        self.profiles = profiles
        profileObserver = NotificationCenter.default.addObserver(forName: T1ProfileStore.changed, object: profiles, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.configurationChanged(appID: app?.bundleIdentifier)
        }
    }

    deinit {
        if let profileObserver { NotificationCenter.default.removeObserver(profileObserver) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
    }

    private func configurationChanged(appID: String? = nil) {
        cancelLocalVoice()
        for press in buttonPresses.values {
            press.click?.cancel()
            press.hold?.cancel()
        }
        buttonPresses.removeAll()
        applyMapping(nativeOverride: appID.map { profiles.isNative($0) })
    }

    func setupInput() {
        if listening { setupEventTap(); return }
        guard AXIsProcessTrusted(),
              IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: 0x620a, kIOHIDProductIDKey: 0x0407],
            [kIOHIDVendorIDKey: 0x1915, kIOHIDProductIDKey: 0x1025, kIOHIDTransportKey: "USB"]
        ] as CFArray)
        IOHIDManagerRegisterInputReportCallback(manager, { context, status, sender, _, id, report, length in
            guard let context, let sender, status == noErr, length > 0, length <= 16 else { return }
            let controller = Unmanaged<T1Controller>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            controller.inputReport(id, Array(UnsafeBufferPointer(start: report, count: length)), from: device)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, status, _, device in
            guard let context, status == noErr else { return }
            Unmanaged<T1Controller>.fromOpaque(context).takeUnretainedValue().deviceChanged(device, attached: true)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<T1Controller>.fromOpaque(context).takeUnretainedValue().deviceChanged(device, attached: false)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        listening = IOHIDManagerOpen(manager, 0) == kIOReturnSuccess
        if !listening {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        log("控制器输入监控：\(listening ? "就绪" : "未授权")")
        if listening { setupEventTap(); applyMapping() }
    }

    func selectConnection(_ mode: T1ConnectionMode) {
        guard mode != connectionMode else { return }
        let previous = transport
        connectionMode = mode
        trace("连接偏好：\(mode.title)")
        if transport != previous { remoteDisconnected() }
        applyMapping()
        connectionChanged()
    }

    private func deviceChanged(_ device: IOHIDDevice, attached: Bool) {
        let previous = transport
        let isReceiver = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int == 0x1915
        let wasAttached = isReceiver ? receiverAttached : !bluetoothDevices.isEmpty
        if isReceiver {
            if attached { receiverDevices.insert(device) }
            else if receiverDevices.remove(device) != nil && !receiverAttached { receiverActive = false }
        } else {
            if attached { bluetoothDevices.insert(device) }
            else { bluetoothDevices.remove(device) }
        }
        let isAttached = isReceiver ? receiverAttached : !bluetoothDevices.isEmpty
        if isAttached != wasAttached {
            trace("\(isReceiver ? "2.4G 接收器" : "蓝牙 HID")：\(isAttached ? "已接入" : "已断开")")
        }
        if transport != previous { trace("控制通道：\(transport == .bluetooth ? "蓝牙" : "2.4G")") }
        if transport != previous || (!attached && (isReceiver ? previous == .receiver && !receiverAttached
                                                             : previous == .bluetooth && bluetoothDevices.isEmpty)) {
            remoteDisconnected()
        }
        applyMapping()
        connectionChanged()
    }

    private func inputReport(_ id: UInt32, _ data: [UInt8], from device: IOHIDDevice) {
        if receiverDevices.contains(device) {
            if !receiverActive && data.dropFirst(id == 0 ? 0 : 1).contains(where: { $0 != 0 }) {
                receiverActive = true
                trace("2.4G：收到接收器首个输入")
                connectionChanged()
            }
            guard transport == .receiver else { return }
            if id == 0, data.count >= 3 {
                update(T1Button.menu.rawValue, down: data.dropFirst(2).contains(0x65))
            } else if id == 2, data.count >= 3 {
                updateConsumer(UInt16(data[1]) | UInt16(data[2]) << 8, voiceUsage: 0xCF)
            }
        } else if transport == .bluetooth {
            onReport(id, data)
        }
    }

    func requestPermissions() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        setupInput()
    }

    func stop() {
        applyMapping(restoreReceiver: true)
        mappingQueue.sync {}
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        eventTap = nil
        eventTapSource = nil
        remoteDisconnected()
        if let pid = voiceTarget { finishVoice(pid, cancel: true) }
        if listening {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
    }

    func remoteDisconnected() {
        cancelLocalVoice()
        systemNavigation.close()
        chatActionGeneration += 1
        mouseBackCaptured = false
        shutdownClickCaptured = false
        capturedNavigation.removeAll()
        keys.removeAll()
        powerClick?.cancel()
        powerClick = nil
        powerHold?.cancel()
        powerHold = nil
        for press in buttonPresses.values {
            press.click?.cancel()
            press.hold?.cancel()
        }
        buttonPresses.removeAll()
    }

    private func onReport(_ reportID: UInt32, _ data: [UInt8]) {
        switch reportID {
        case 1 where data.count >= 4:
            update(0x70065, down: data.dropFirst(3).contains(0x65))
        case 2 where data.count >= 3:
            let usage = UInt16(data[1]) | UInt16(data[2]) << 8
            updateConsumer(usage, voiceUsage: 0x221)
        case 3 where data.count >= 2:
            update(0x10081, down: (data[1] & 1) != 0)
        default: break
        }
    }

    private func updateConsumer(_ usage: UInt16, voiceUsage: UInt16) {
        update(0xC0221, down: usage == voiceUsage)
        update(T1Button.home.rawValue, down: usage == 0x223)
        update(T1Button.back.rawValue, down: usage == 0x224)
        update(T1Button.mute.rawValue, down: usage == 0xE2)
    }

    private func update(_ key: UInt32, down: Bool) {
        if down {
            guard keys.insert(key).inserted else { return }
            if let name = T1Button(rawValue: key)?.title ?? (key == 0x10081 ? "电源键" : key == 0xC0221 ? "语音键" : nil) {
                trace("收到 \(transport == .bluetooth ? "蓝牙" : "2.4G") \(name)")
            }
        } else {
            guard keys.remove(key) != nil else { return }
        }
        guard AXIsProcessTrusted(), !profiles.recordingShortcut else { return }
        guard shutdownWindow == nil else { return }
        if key == 0x10081 {
            power(down)
            return
        }
        if down, key == T1Button.back.rawValue, systemNavigation.backPressed() { return }
        guard !profiles.isNative(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        if down, key == T1Button.back.rawValue, dismissCodexSearch() { return }
        if let button = T1Button(rawValue: key) {
            handleButton(button, down: down)
            return
        }
        if down, key == 0xC0221 {
            if transport == .receiver && receiverVoiceKey() { return }
            guard handlesVoiceKey() else { return }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == appID {
                log("收到 T1 语音键")
                voicePressed()
            } else if UserDefaults.standard.bool(forKey: T1ProfileStore.localDictationEnabledKey) {
                localVoiceKey()
            }
        }
    }

    private func handleButton(_ button: T1Button, down: Bool) {
        if down {
            let previous = buttonPresses.removeValue(forKey: button)
            previous?.click?.cancel()
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            if let previous, previous.click != nil, previous.pid == pid {
                perform(previous.double, button: button, gesture: .double, pid: pid)
                return
            }

            let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            var single = profiles.effective(button, .single, appID: appID)
            if button == .back && mouseBackCaptured && single.action == .none { single = T1Binding(.rightClick) }
            let double = profiles.effective(button, .double, appID: appID)
            let long = profiles.effective(button, .hold, appID: appID)
            if double.action == .none && long.action == .none {
                perform(single, button: button, gesture: .single, pid: pid)
                return
            }

            var press = ButtonPress(pid: pid, single: single, double: double)
            if long.action != .none {
                let hold = DispatchWorkItem { [weak self] in
                    guard let self, self.keys.contains(button.rawValue) else { return }
                    self.buttonPresses.removeValue(forKey: button)
                    self.perform(long, button: button, gesture: .hold, pid: pid)
                }
                press.hold = hold
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: hold)
            }
            buttonPresses[button] = press
            return
        }

        guard var press = buttonPresses.removeValue(forKey: button) else { return }
        press.hold?.cancel()
        press.hold = nil
        let pid = press.pid
        let single = press.single
        guard press.double.action != .none else {
            perform(single, button: button, gesture: .single, pid: pid)
            return
        }
        let click = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.buttonPresses.removeValue(forKey: button)
            self.perform(single, button: button, gesture: .single, pid: pid)
        }
        press.click = click
        buttonPresses[button] = press
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: click)
    }

    private func perform(_ binding: T1Binding, button: T1Button, gesture: T1Gesture, pid: pid_t) {
        let action = binding.action
        guard action != .none && action != .inherit else {
            trace("\(button.title) \(gesture.title)：无绑定动作")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == pid, front.bundleIdentifier != "com.apple.loginwindow" else {
            trace("\(button.title) \(gesture.title)：目标窗口已切换，跳过动作")
            return
        }
        if action == .native {
            if let code = button.navigationKeyCode {
                post(code, flags: [])
                trace("派发 \(button.title) 原生动作 [\(front.bundleIdentifier ?? "未知 App")]")
            }
            return
        }
        let definition = action.definition
        let profile = profiles.profile(front.bundleIdentifier)
        let explicit = profile?.enabled == true && profiles.binding(button, gesture, in: front.bundleIdentifier).action != .inherit
        guard definition.global || foregroundPID() == pid || explicit else { return }
        if action == .customShortcut {
            guard let shortcut = binding.shortcut, shortcut.valid else { return }
            post(shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers))
            if shortcut.keyCode == 3 && shortcut.modifiers == CGEventFlags.maskCommand.rawValue {
                cacheCodexSearch(after: pid)
            }
        } else if action == .codexSendOrStop {
            performCodexOK(pid: pid)
            return
        } else if let media = [T1ButtonAction.mute: 7, .playPause: 16, .nextTrack: 17, .previousTrack: 18][action] {
            postMedia(media)
        } else if action == .rightClick {
            let point = CGEvent(source: nil)?.location ?? .zero
            for type: CGEventType in [.rightMouseDown, .rightMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right)
                event?.setIntegerValueField(.eventSourceUserData, value: T1DeviceEvent.tag)
                event?.post(tap: .cghidEventTap)
            }
        } else if action == .appsMenu {
            systemNavigation.showApps()
        } else if action == .runningApps {
            systemNavigation.showSwitcher()
        } else if action == .showDesktop {
            systemNavigation.showDesktop()
        } else if action == .activateChatGPT || action == .codexMode || action == .newChat {
            systemNavigation.close()
            openChatGPT(action, from: pid)
        } else if let code = definition.key {
            post(code, flags: definition.modifiers)
            if action == .findInChat { cacheCodexSearch(after: pid) }
        }
        log("派发 \(button.title) \(gesture.title) → \(definition.title) [\(front.bundleIdentifier ?? "未知 App")]")
    }

    private func openChatGPT(_ action: T1ButtonAction, from pid: pid_t) {
        chatActionGeneration += 1
        let generation = chatActionGeneration
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first,
           window(app.processIdentifier) != nil {
            if foregroundPID() != app.processIdentifier { app.activate() }
            if action != .activateChatGPT {
                waitForChatGPT(action, from: pid, target: app.processIdentifier, generation: generation,
                               deadline: ProcessInfo.processInfo.systemUptime + 4)
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] app, _ in
                guard let app, action != .activateChatGPT else { return }
                let target = app.processIdentifier
                DispatchQueue.main.async {
                    self?.waitForChatGPT(action, from: pid, target: target, generation: generation,
                                         deadline: ProcessInfo.processInfo.systemUptime + 4)
                }
            }
        }
    }

    private func waitForChatGPT(_ action: T1ButtonAction, from pid: pid_t, target: pid_t,
                                generation: Int, deadline: TimeInterval) {
        guard chatActionGeneration == generation,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front == pid || front == target, ProcessInfo.processInfo.systemUptime < deadline else { return }
        let definition = action.definition
        if front == target, window(target) != nil, let key = definition.key {
            post(key, flags: definition.modifiers, to: target)
            log("ChatGPT 已收到\(definition.title)快捷键")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.waitForChatGPT(action, from: pid, target: target, generation: generation, deadline: deadline)
        }
    }

    private func power(_ down: Bool) {
        if down {
            longFired = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.keys.contains(0x10081) else { return }
                self.powerClick?.cancel()
                self.powerClick = nil
                self.longFired = true
                self.confirmShutdown()
            }
            powerHold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            return
        }
        powerHold?.cancel()
        if longFired { return }
        if let first = powerClick {
            first.cancel()
            powerClick = nil
            lock()
            trace("电源键双击：已请求锁屏并熄屏")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                task.arguments = ["displaysleepnow"]
                try? task.run()
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.powerClick = nil
                self?.lock()
                self?.trace("电源键单击：已请求锁屏")
            }
            powerClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
        }
    }

    private func lock() { post(12, flags: [.maskControl, .maskCommand]) }

    private func confirmShutdown() {
        systemNavigation.close()
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "关闭这台 Mac？"
        dialog.informativeText = "用遥控器左右键选择，按 OK 确认。"
        let shutdown = dialog.addButton(withTitle: "关机")
        let cancel = dialog.addButton(withTitle: "取消")
        let window = dialog.window
        var selected = cancel
        func select(_ button: NSButton) {
            selected = button
            shutdown.keyEquivalent = button === shutdown ? "\r" : ""
            cancel.keyEquivalent = button === cancel ? "\r" : "\u{1b}"
            window.defaultButtonCell = button.cell as? NSButtonCell
        }
        select(cancel)
        trace("电源键长按：打开关机确认框")
        shutdownWindow = window
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow === window else { return event }
            let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(modifiers).isEmpty else { return event }
            switch event.keyCode {
            case 123, 124:
                let shutdownX = shutdown.convert(shutdown.bounds, to: nil).midX
                let cancelX = cancel.convert(cancel.bounds, to: nil).midX
                let shutdownOnLeft = shutdownX < cancelX
                let pressedLeft = event.keyCode == 123
                select(pressedLeft == shutdownOnLeft ? shutdown : cancel)
                if !event.isARepeat { self.trace("关机确认：选中「\(selected.title)」") }
            case 36, 76:
                if !event.isARepeat { selected.performClick(nil) }
            case 53: cancel.performClick(nil)
            default: return event
            }
            return nil
        }
        let response = dialog.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        shutdownWindow = nil
        guard response == .alertFirstButtonReturn else {
            log("T1 关机确认：已取消")
            return
        }
        log("T1 关机确认：已确认")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to shut down"]
        try? task.run()
    }

    func voicePressed() {
        guard !profiles.recordingShortcut,
              !profiles.isNative(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        guard AXIsProcessTrusted() else { log("听写控制需要辅助功能权限"); return }
        if let pid = voiceTarget {
            if !nativeStartRequested {
                finishVoice(pid, cancel: true)
                return
            }
            if let pending = voiceClick {
                pending.cancel()
                voiceClick = nil
                finishVoice(pid, cancel: true)
            } else {
                let pending = DispatchWorkItem { [weak self] in
                    self?.voiceClick = nil
                    self?.finishVoice(pid, cancel: false)
                }
                voiceClick = pending
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: pending)
            }
            return
        }
        guard let pid = foregroundPID(), let targetWindow = window(pid),
              buttonPoint(startLabels, pid: pid) != nil else {
            log("未找到前台 ChatGPT 输入框的听写按钮")
            return
        }
        voiceTarget = pid
        voiceWindow = targetWindow
        nativeStartRequested = false
        idleVoiceChecks = 0
        voiceGeneration += 1
        let generation = voiceGeneration
        // Let the remote finish its physical button transition before MIC_OPEN.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, self.voiceGeneration == generation, self.voiceTarget == pid else { return }
            guard self.foregroundPID() == pid, self.openMic() else {
                self.log("T1 麦克风未就绪，未启动听写")
                self.finishVoice(pid, cancel: true)
                return
            }
            self.controllerOpenedMic = true
            self.awaitAudio(pid, generation: generation,
                            deadline: ProcessInfo.processInfo.systemUptime + 3)
        }
    }

    private func awaitAudio(_ pid: pid_t, generation: Int, deadline: TimeInterval) {
        guard voiceTarget == pid, voiceGeneration == generation else { return }
        guard let targetWindow = voiceWindow, let actualWindow = window(pid),
              CFEqual(targetWindow, actualWindow), foregroundPID() == pid else {
            finishVoice(pid, cancel: true)
            return
        }
        if !audioReady() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                log("未确认 T1 音频进入系统，未启动听写")
                finishVoice(pid, cancel: true)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.awaitAudio(pid, generation: generation, deadline: deadline)
            }
            return
        }
        log("已确认 T1 音频进入系统")
        guard clickButton(startLabels, pid: pid) else {
            log("无法点击前台 Codex 听写按钮")
            finishVoice(pid, cancel: true)
            return
        }
        nativeStartRequested = true
        voiceStarted = ProcessInfo.processInfo.systemUptime
        log("已点击 Codex 听写，等待录音控件")
        confirmDictation(pid, generation: generation)
    }

    private func confirmDictation(_ pid: pid_t, generation: Int) {
        guard voiceTarget == pid, voiceGeneration == generation else { return }
        guard foregroundPID() == pid, let previous = voiceWindow, let now = window(pid), CFEqual(previous, now) else {
            finishVoice(pid, cancel: true)
            return
        }
        if buttonPoint(stopLabels, pid: pid) != nil {
            log("Codex 已开始录音")
            return
        }
        guard ProcessInfo.processInfo.systemUptime - voiceStarted < 4 else {
            log("Codex 未显示录音控件，关闭 T1 收音")
            logVoiceControls(pid)
            finishVoice(pid, cancel: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.confirmDictation(pid, generation: generation)
        }
    }

    private func finishVoice(_ pid: pid_t, cancel: Bool) {
        voiceGeneration += 1
        voiceTarget = nil
        let previousWindow = voiceWindow
        voiceWindow = nil
        let started = nativeStartRequested
        nativeStartRequested = false
        voiceClick?.cancel()
        voiceClick = nil
        let shouldClose = controllerOpenedMic
        controllerOpenedMic = false
        defer { if shouldClose { closeMic() } }
        guard started, let previousWindow, let now = window(pid), CFEqual(previousWindow, now) else { return }
        let labels = cancel ? cancelLabels : stopLabels
        if clickButton(labels, pid: pid) {
            log(cancel ? "已点击作废听写" : "已点击结束听写，等待草稿")
        } else {
            logVoiceControls(pid)
            log(cancel ? "未找到可点击的作废按钮" : "未找到可点击的结束按钮")
        }
    }

    func microphoneInterrupted() {
        if let pid = voiceTarget { finishVoice(pid, cancel: true) }
    }

    func checkVoice() {
        guard let pid = voiceTarget, nativeStartRequested, voiceClick == nil,
              ProcessInfo.processInfo.systemUptime - voiceStarted > 4 else { return }
        guard foregroundPID() == pid, let previous = voiceWindow, let now = window(pid), CFEqual(previous, now) else {
            finishVoice(pid, cancel: true)
            return
        }
        if buttonPoint(stopLabels.union(cancelLabels), pid: pid) != nil {
            idleVoiceChecks = 0
        } else if buttonPoint(startLabels, pid: pid) != nil {
            idleVoiceChecks += 1
            if idleVoiceChecks >= 2 {
                log("原生听写已回到待命，释放 T1 飞鼠")
                finishVoice(pid, cancel: true)
            }
        } else {
            idleVoiceChecks = 0
        }
    }

    func applyVoiceFallbackMapping() {
        mappingQueue.async {
            let target = #"{"VendorID":25098,"ProductID":1031,"Product":"T1-Remote"}"#
            let read = Process()
            let output = Pipe()
            read.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            read.arguments = ["property", "--matching", target, "--get", "UserKeyMapping"]
            read.standardOutput = output
            guard (try? read.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            read.waitUntilExit()
            guard read.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  text.contains("UserKeyMapping"),
                  !text.contains("HIDKeyboardModifierMappingSrc"),
                  (text.contains("(null)") || text.contains("(\n)")) else { return }
            let write = Process()
            write.executableURL = read.executableURL
            write.arguments = ["property", "--matching", target, "--set",
                #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC00000221,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#]
            write.standardOutput = FileHandle.nullDevice
            write.standardError = FileHandle.nullDevice
            if (try? write.run()) != nil { write.waitUntilExit() }
        }
    }

    func applyMapping(nativeOverride: Bool? = nil, restoreReceiver: Bool = false) {
        guard listening && AXIsProcessTrusted() else { return }
        let native = nativeOverride ?? profiles.isNative(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let bluetooth = transport == .bluetooth
        let usb = receiverAttached
        mappingQueue.async {
            if !restoreReceiver {
                Self.applyMapping(
                    matching: #"{"VendorID":25098,"ProductID":1031,"Product":"T1-Remote"}"#,
                    native: native || !bluetooth, keepPower: bluetooth)
            }
            if usb {
                let usbNative = native || bluetooth || restoreReceiver
                Self.applyMapping(
                    matching: #"{"VendorID":6421,"ProductID":4133,"Transport":"USB","PrimaryUsagePage":1,"PrimaryUsage":6}"#,
                    native: usbNative, replacements: [0x700000065: 0x70000006F], keepPower: false)
                Self.applyMapping(
                    matching: #"{"VendorID":6421,"ProductID":4133,"Transport":"USB","PrimaryUsagePage":1,"PrimaryUsage":2}"#,
                    native: usbNative, replacements: [
                        0xC000000CF: 0x70000006D, 0xC00000224: 0x70000006C,
                        0xC00000223: 0x70000006B, 0xC000000E2: 0x700000068
                    ], keepPower: false)
            }
        }
    }

    private static func applyMapping(matching match: String, native: Bool,
                                     replacements: [UInt64: UInt64] = T1DeviceMapping.replacements,
                                     keepPower: Bool) {
        let pipe = Pipe()
        let read = Process()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        read.arguments = ["property", "--matching", match, "--get", "UserKeyMapping"]
        read.standardOutput = pipe
        guard (try? read.run()) != nil else { return }
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        read.waitUntilExit()
        guard read.terminationStatus == 0, let text = String(data: bytes, encoding: .utf8),
              text.contains("UserKeyMapping") else { return }
        func values(_ field: String) -> [UInt64] {
            text.components(separatedBy: .newlines).compactMap { line in
                guard line.contains(field), let part = line.split(separator: "=").last else { return nil }
                return UInt64(part.trimmingCharacters(in: CharacterSet(charactersIn: " ;\t")))
            }
        }
        let src = values("HIDKeyboardModifierMappingSrc")
        let dst = values("HIDKeyboardModifierMappingDst")
        guard src.count == dst.count, Set(src).count == src.count else { return }
        let original = Dictionary(uniqueKeysWithValues: zip(src, dst))
        let mapping = T1DeviceMapping.apply(to: original, native: native,
                                            replacements: replacements, keepPower: keepPower)
        guard mapping != original else { return }
        let json = mapping.map { ["HIDKeyboardModifierMappingSrc": $0.key, "HIDKeyboardModifierMappingDst": $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": json]),
              let payload = String(data: data, encoding: .utf8) else { return }
        let write = Process()
        write.executableURL = read.executableURL
        write.arguments = ["property", "--matching", match, "--set", payload]
        write.standardOutput = FileHandle.nullDevice
        write.standardError = FileHandle.nullDevice
        if (try? write.run()) != nil { write.waitUntilExit() }
    }

    private func setupEventTap() {
        guard eventTap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<T1Controller>.fromOpaque(context).takeUnretainedValue()
                return controller.handleEvent(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            log("T1 自定义鼠标按键监听未就绪")
            return
        }
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            trace("按键监听曾暂停，已尝试重新启用")
            return false
        }
        let leftClick = type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged
        if leftClick && shutdownWindow == nil && !shutdownClickCaptured { return false }
        guard event.getIntegerValueField(.eventSourceUserData) != T1DeviceEvent.tag,
              T1DeviceEvent.transport(event) == transport else { return false }
        if leftClick {
            if type == .leftMouseDown { shutdownClickCaptured = shutdownWindow?.isKeyWindow == true }
            guard shutdownClickCaptured else { return false }
            if type == .leftMouseUp {
                shutdownClickCaptured = false
                if shutdownWindow?.isKeyWindow == true { post(36, flags: [], to: getpid()) }
            }
            return true
        }
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if T1DeviceEvent.placeholderKeys.contains(code) { return true }
            guard let button = T1Button.allCases.first(where: { $0.navigationKeyCode.map(Int64.init) == code }) else {
                return false
            }
            if type == .keyUp {
                guard capturedNavigation.remove(button) != nil else { return false }
                update(button.rawValue, down: false)
                return true
            }
            guard shutdownWindow == nil else { return false }
            if capturedNavigation.contains(button) { return true }
            let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            guard !systemNavigation.isActive, !profiles.recordingShortcut,
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  event.flags.intersection(modifiers).isEmpty else {
                return false
            }
            let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard profiles.customizesNavigation(button, in: appID) else {
                trace("收到 \(transport == .bluetooth ? "蓝牙" : "2.4G") \(button.title)，原生直通 [\(appID ?? "未知 App")]")
                return false
            }
            capturedNavigation.insert(button)
            update(button.rawValue, down: true)
            return true
        }
        guard shutdownWindow == nil, !systemNavigation.isActive, !profiles.recordingShortcut else { return false }
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !profiles.isNative(appID) else { return false }
        if type == .rightMouseDown, let pid = foregroundPID(), let button = codexSearchCloseButton(pid) {
            mouseBackCaptured = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.foregroundPID() == pid, self.validSearchClose(button) else { return }
                self.post(53, flags: [], to: pid)
                self.searchCloseCache = nil
                self.log("T1 返回键：关闭 Codex 查找")
            }
            return true
        }
        let customBack = T1Gesture.allCases.contains {
            let action = profiles.effective(.back, $0, appID: appID).action
            return action != .none && action != .native
        }
        switch type {
        case .rightMouseDown where customBack:
            mouseBackCaptured = true
            update(T1Button.back.rawValue, down: true)
            return true
        case .rightMouseUp where mouseBackCaptured:
            mouseBackCaptured = false
            update(T1Button.back.rawValue, down: false)
            return true
        case .rightMouseDragged where mouseBackCaptured: return true
        default: return false
        }
    }

    private func validSearchClose(_ button: AXUIElement) -> Bool {
        value(button, kAXRoleAttribute) as? String == kAXButtonRole &&
        value(button, kAXParentAttribute) != nil &&
        value(button, "AXHidden") as? Bool != true &&
        frame(of: button) != nil
    }

    private func cacheCodexSearch(after pid: pid_t) {
        guard foregroundPID() == pid else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.foregroundPID() == pid else { return }
            _ = self.codexSearchCloseButton(pid)
        }
    }

    private func codexSearchCloseButton(_ pid: pid_t) -> AXUIElement? {
        guard let currentWindow = window(pid) else { return nil }
        if let cached = searchCloseCache, cached.pid == pid, CFEqual(cached.window, currentWindow),
           validSearchClose(cached.button) { return cached.button }
        searchCloseCache = nil
        let application = AXUIElementCreateApplication(pid)
        guard let focused = value(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var scope = unsafeBitCast(focused, to: AXUIElement.self)
        for _ in 0..<4 {
            guard value(scope, kAXRoleAttribute) as? String != "AXWebArea" else { break }
            let children = value(scope, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for button in children where isControl(button) {
                if !searchCloseLabels.isDisjoint(with: controlNames(button)), validSearchClose(button) {
                    searchCloseCache = (pid, currentWindow, button)
                    return button
                }
            }
            guard let parent = value(scope, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            scope = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return nil
    }

    @discardableResult
    private func dismissCodexSearch() -> Bool {
        guard let pid = foregroundPID(), codexSearchCloseButton(pid) != nil else { return false }
        post(53, flags: [], to: pid)
        searchCloseCache = nil
        log("T1 返回键：关闭 Codex 查找")
        return true
    }

    private func postMedia(_ code: Int) {
        for down in [true, false] {
            let state = down ? 0xA00 : 0xB00
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)), timestamp: 0, windowNumber: 0,
                context: nil, subtype: 8, data1: (code << 16) | state, data2: -1)?.cgEvent else { return }
            event.setIntegerValueField(.eventSourceUserData, value: T1DeviceEvent.tag)
            event.post(tap: .cghidEventTap)
        }
    }

    private func foregroundPID() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == appID else { return nil }
        return app.processIdentifier
    }

    private func post(_ code: CGKeyCode, flags: CGEventFlags, to pid: pid_t? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: T1DeviceEvent.tag)
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }
    }

    private func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success ? result : nil
    }

    private func window(_ pid: pid_t) -> AXUIElement? {
        guard let element = value(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(element, to: AXUIElement.self)
    }

    private func find(_ pid: pid_t, match: (AXUIElement) -> Bool) -> AXUIElement? {
        guard let root = window(pid) else { return nil }
        var nodes: [AXUIElement] = [root]
        var remaining = 2800
        while let node = nodes.popLast(), remaining > 0 {
            remaining -= 1
            if match(node) { return node }
            if let children = value(node, kAXChildrenAttribute) as? [AXUIElement] {
                nodes.append(contentsOf: children)
            }
        }
        return nil
    }

    private func controlNames(_ node: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXLabel", kAXIdentifierAttribute]
            .compactMap { value(node, $0) as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.count < 90 }
    }

    private func isControl(_ node: AXUIElement) -> Bool {
        guard let role = value(node, kAXRoleAttribute) as? String else { return false }
        return [kAXButtonRole, kAXCheckBoxRole, kAXMenuButtonRole, kAXPopUpButtonRole, "AXToggle"].contains(role)
    }

    private func performCodexOK(pid: pid_t) {
        guard foregroundPID() == pid else { return }
        var buttonLabel = ""
        let button = find(pid) { node in
            guard value(node, kAXRoleAttribute) as? String == kAXButtonRole else { return false }
            let names = controlNames(node)
            let stopping = !replyStopLabels.isDisjoint(with: names)
            guard stopping || !replyResumeLabels.isDisjoint(with: names),
                  let parent = value(node, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            let group = unsafeBitCast(parent, to: AXUIElement.self)
            let siblings = value(group, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard siblings.contains(where: { value($0, kAXRoleAttribute) as? String == kAXTextAreaRole }) else {
                return false
            }
            buttonLabel = stopping ? "停止" : "继续"
            return true
        }
        if let button {
            if value(button, kAXEnabledAttribute) as? Bool != false,
               let point = buttonPoint(button), click(at: point, pid: pid) {
                log("T1 OK：已请求\(buttonLabel) Codex 当前回复")
            } else {
                log("T1 OK：未能点击 Codex「\(buttonLabel)」")
            }
        } else if foregroundPID() == pid {
            post(36, flags: [])
            log("T1 OK：Codex 回车")
        }
    }

    private func buttonPoint(_ labels: Set<String>, pid: pid_t) -> CGPoint? {
        guard foregroundPID() == pid else { return nil }
        var point: CGPoint?
        _ = find(pid) { node in
            guard self.isControl(node), self.value(node, kAXEnabledAttribute) as? Bool != false else { return false }
            let matches = self.controlNames(node).contains { name in
                if labels.contains(name) { return true }
                return labels.contains { label in
                    name.hasPrefix(label + " (") || name.hasPrefix(label + "（") ||
                    name == label + " esc" || name == label + " escape"
                }
            }
            guard matches else { return false }
            point = self.buttonPoint(node)
            return point != nil
        }
        return point
    }

    private func buttonPoint(_ button: AXUIElement) -> CGPoint? {
        guard let frame = frame(of: button) else { return nil }
        let system = AXUIElementCreateSystemWide()
        let x = frame.midX, y = frame.midY
        let dx = min(6, frame.width / 4), dy = min(6, frame.height / 4)
        // Chromium can return the outer group at the center of an icon.
        let candidates = [
            CGPoint(x: x, y: y),
            CGPoint(x: x + dx, y: y), CGPoint(x: x - dx, y: y),
            CGPoint(x: x, y: y - dy), CGPoint(x: x, y: y + dy),
            CGPoint(x: x - dx, y: y - dy), CGPoint(x: x + dx, y: y + dy)
        ]
        return candidates.first { hitsButton(button, at: $0, in: system) }
    }

    private func hitsButton(_ button: AXUIElement, at point: CGPoint, in system: AXUIElement) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else { return false }
        while let current = hit {
            if CFEqual(current, button) { return true }
            guard !isControl(current), let parent = value(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(current, parent) else { return false }
            hit = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }

    private func frame(of node: AXUIElement) -> CGRect? {
        guard let position = value(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 1, dimensions.height > 1 else { return nil }
        let frame = CGRect(origin: origin, size: dimensions)
        guard frame.midX.isFinite, frame.midY.isFinite else { return nil }
        return frame
    }

    private func clickButton(_ labels: Set<String>, pid: pid_t) -> Bool {
        guard let point = buttonPoint(labels, pid: pid) else { return false }
        return click(at: point, pid: pid)
    }

    private func click(at point: CGPoint, pid: pid_t) -> Bool {
        guard foregroundPID() == pid,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
        for event in [down, up] {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private func logVoiceControls(_ pid: pid_t) {
        var names = Set<String>()
        _ = find(pid) { node in
            guard self.isControl(node) else { return false }
            for name in self.controlNames(node) where ["dictat", "听写", "聽寫", "转录", "轉錄"].contains(where: name.contains) {
                if !name.contains("send") && !name.contains("发送") && !name.contains("傳送") { names.insert(name) }
            }
            return false
        }
        log("听写控件：发现 \(names.count) 个匹配标签")
    }

}
