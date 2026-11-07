import ApplicationServices
import IOKit.hid
import AppKit
import AudioToolbox
import CoreAudio
import CoreBluetooth
import Foundation
import SwiftUI

private let compatibilityInput = "T1 USB-Compatible Mic"
private let compatibilityMirrorUID = "T1SiriInput2ch_2_UID"
private let deviceName: String = {
    if CommandLine.arguments.contains("--siri-input") { return compatibilityInput }
    if !CommandLine.arguments.contains("--blackhole"),
       let devices = try? audioDevices(), devices.contains(where: {
           (stringProperty($0, kAudioObjectPropertyName) as String?) == compatibilityInput
       }) { return compatibilityInput }
    return "BlackHole 2ch"
}()

private func currentInputName() -> String? {
    var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout.size(ofValue: device))
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr
    else { return nil }
    return stringProperty(device, kAudioObjectPropertyName) as String?
}

enum BridgeError: LocalizedError {
    case missingDevice
    case audio(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .missingDevice: return "未找到 \(deviceName)。请检查驱动是否已被系统加载。"
        case let .audio(step, status): return "\(step)失败（\(status)）"
        }
    }
}

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> CFString? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    let result = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard result == noErr else { return nil }
    return value
}

func audioDevices() throws -> [AudioDeviceID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var result = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
    guard result == noErr else { throw BridgeError.audio("查询音频设备", result) }
    guard size > 0 else { throw BridgeError.missingDevice }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    result = ids.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
    }
    guard result == noErr else { throw BridgeError.audio("读取音频设备", result) }
    return ids
}

func visibleOutputUID() throws -> CFString {
    for id in try audioDevices() where (stringProperty(id, kAudioObjectPropertyName) as String?) == deviceName {
        if let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) { return uid }
    }
    throw BridgeError.missingDevice
}

// BLE notifications and audio queue callbacks both run on the main run loop.
final class Loopback {
    private var queue: AudioQueueRef?
    private let bufferFrames = 512
    private var samples = [Int16](repeating: 0, count: 8192)
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private(set) var deliveredFrames: UInt64 = 0

    @discardableResult
    func open() throws -> String {
        if deviceName == compatibilityInput, #available(macOS 15.0, *),
           let mirror = try? AudioHardwareSystem.shared.device(forUID: compatibilityMirrorUID) {
            // Keep the injected signal off the public output that call echo cancellation can tap.
            do {
                // The two HAL engines run independently. A shorter write cycle prevents
                // the public input from treating the shared ring buffer as stale.
                var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var frames: UInt32 = 128
                try checked(AudioObjectSetPropertyData(mirror.id, &property, 0, nil,
                    UInt32(MemoryLayout<UInt32>.size), &frames), "设置 T1 隐藏输出缓冲")
                try open(uid: compatibilityMirrorUID as CFString)
                return compatibilityMirrorUID
            } catch {
                close()
            }
        }
        let uid = try visibleOutputUID()
        try open(uid: uid)
        return uid as String
    }

    private func open(uid: CFString) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        let result = AudioQueueNewOutput(&format, { context, queue, buffer in
            guard let context else { return }
            let sink = Unmanaged<Loopback>.fromOpaque(context).takeUnretainedValue()
            sink.fill(queue, buffer)
        }, Unmanaged.passUnretained(self).toOpaque(), CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, 0, &queue)
        guard result == noErr, let queue else { throw BridgeError.audio("创建音频输出", result) }

        do {
            var target: CFString? = uid
            let size = UInt32(MemoryLayout.size(ofValue: target))
            let routeStatus = withUnsafePointer(to: &target) {
                AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, size)
            }
            try checked(routeStatus, "连接 BlackHole")
            try verify(queue, uid: uid)
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                try checked(AudioQueueAllocateBuffer(queue, UInt32(bufferFrames * 4), &buffer), "分配音频缓冲")
                guard let buffer else { throw BridgeError.audio("分配音频缓冲", -1) }
                try checked(fill(queue, buffer), "排入音频缓冲")
            }
            try checked(AudioQueueStart(queue, nil), "启动虚拟麦克风输出")
            try verify(queue, uid: uid)
        } catch {
            close()
            throw error
        }
    }

    private func checked(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw BridgeError.audio(action, status) }
    }

    private func verify(_ queue: AudioQueueRef, uid: CFString) throws {
        var actual: CFString?
        var size = UInt32(MemoryLayout.size(ofValue: actual))
        let routeStatus = withUnsafeMutablePointer(to: &actual) {
            AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, &size)
        }
        try checked(routeStatus, "核对音频设备")
        guard (actual as String?) == (uid as String) else { throw BridgeError.audio("核对 BlackHole 路由", -1) }
    }

    func push(_ decoded: [Int16]) {
        for sample in decoded {
            if available == samples.count {
                readIndex = (readIndex + 1) % samples.count
                available -= 1
            }
            samples[writeIndex] = sample
            writeIndex = (writeIndex + 1) % samples.count
            available += 1
        }
    }

    @discardableResult
    private func fill(_ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef) -> OSStatus {
        let out = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        let audioFrames = min(available, bufferFrames)
        for frame in 0..<bufferFrames {
            let sample: Int16
            if available > 0 {
                sample = samples[readIndex]
                readIndex = (readIndex + 1) % samples.count
                available -= 1
            } else {
                sample = 0
            }
            out[2 * frame] = sample
            out[2 * frame + 1] = sample
        }
        buffer.pointee.mAudioDataByteSize = UInt32(bufferFrames * 4)
        let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if status == noErr { deliveredFrames += UInt64(audioFrames) }
        return status
    }

    func close() {
        if let queue { AudioQueueDispose(queue, true) }
        queue = nil
        available = 0
        readIndex = 0
        writeIndex = 0
    }

    deinit { close() }
}

enum T1Audio {
    private static let steps = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,
        88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,
        1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,
        7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    private static let indexDelta = [-1,-1,-1,-1,2,4,6,8]

    static func decode(_ data: Data) -> [Int16]? {
        let frame = [UInt8](data)
        guard frame.count == 134, frame[2] == 0, frame[5] <= 88 else { return nil }
        var predictor = Int(Int16(bitPattern: UInt16(frame[3]) << 8 | UInt16(frame[4])))
        var index = Int(frame[5])
        var pcm: [Int16] = []
        pcm.reserveCapacity(256)
        for byte in frame.dropFirst(6) {
            for nibble in [Int(byte >> 4), Int(byte & 15)] {
                let step = steps[index]
                var delta = step >> 3
                if nibble & 4 != 0 { delta += step }
                if nibble & 2 != 0 { delta += step >> 1 }
                if nibble & 1 != 0 { delta += step >> 2 }
                predictor = max(-32768, min(32767, predictor + (nibble & 8 == 0 ? delta : -delta)))
                index = max(0, min(88, index + indexDelta[nibble & 7]))
                pcm.append(Int16(predictor))
            }
        }
        return pcm
    }
}

@available(macOS 15.0, *)
final class DefaultInputActivity {
    private let hal = AudioHardwareSystem.shared
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let changed: (Set<AudioObjectID>) -> Void
    private var watchedProcesses = Set<AudioObjectID>()
    private var activeClients = Set<AudioObjectID>()
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refresh()
    }

    init(changed: @escaping (Set<AudioObjectID>) -> Void) {
        self.changed = changed
    }

    func start() {
        observe(system, kAudioHardwarePropertyProcessObjectList, add: true)
        observe(system, kAudioHardwarePropertyDefaultInputDevice, add: true)
        refresh()
    }

    func stop() {
        observe(system, kAudioHardwarePropertyProcessObjectList, add: false)
        observe(system, kAudioHardwarePropertyDefaultInputDevice, add: false)
        for id in watchedProcesses { observeProcess(id, add: false) }
        watchedProcesses.removeAll()
    }

    private func refresh() {
        let processes = (try? hal.processes) ?? []
        let clients = processes.filter { (try? $0.pid) != getpid() }
        let current = Set(clients.map(\.id))
        for id in watchedProcesses.subtracting(current) { observeProcess(id, add: false) }
        for id in current.subtracting(watchedProcesses) { observeProcess(id, add: true) }
        watchedProcesses = current

        var active = Set<AudioObjectID>()
        if let input = try? hal.defaultInputDevice, (try? input.name) == compatibilityInput {
            for process in clients where (try? process.isRunningInput) == true && usesInput(input.id, process: process.id) {
                active.insert(process.id)
            }
        }
        guard active != activeClients else { return }
        activeClients = active
        changed(active)
    }

    private func usesInput(_ device: AudioDeviceID, process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioDeviceID>.stride else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr && devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride).contains(device)
    }

    private func observeProcess(_ process: AudioObjectID, add: Bool) {
        observe(process, kAudioProcessPropertyIsRunningInput, add: add)
        observe(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput, add: add)
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, add: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        if add {
            AudioObjectAddPropertyListenerBlock(object, &address, .main, listener)
        } else {
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
    }
}

final class Bridge: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let uuid = (1...4).map { CBUUID(string: "AB5E000\($0)-5A21-4F05-BC7D-AF01F617B664") }
    private let sink = Loopback()
    private var localCapture = false
    private lazy var localDictation = T1LocalDictation(openMic: { [weak self] in
        guard let self, self.ready, !self.recording, self.inputClients.isEmpty else { return false }
        self.localCapture = true
        self.dictationOpenRetried = false
        self.startRecording()
        self.localCapture = self.recording
        return self.recording
    }, closeMic: { [weak self] in
        guard let self, self.localCapture else { return }
        self.localCapture = false
        self.stopRecording()
    }, log: { [weak self] in self?.log($0) })
    private lazy var controller = T1Controller(openMic: { [weak self] in
        guard let self, self.ready, self.inputClients.isEmpty, currentInputName() == deviceName else { return false }
        self.dictationFramesAtStart = self.sink.deliveredFrames
        self.dictationOpenRetried = false
        if !self.recording { self.startRecording() }
        return self.recording
    }, audioReady: { [weak self] in
        guard let self, self.recording, let baseline = self.dictationFramesAtStart,
              let last = self.lastPacket, Date().timeIntervalSince(last) < 0.3,
              currentInputName() == deviceName else { return false }
        return self.sink.deliveredFrames - baseline >= 512
    }, closeMic: { [weak self] in
        self?.stopRecording()
        self?.dictationFramesAtStart = nil
    },
       handlesVoiceKey: { [weak self] in self.map { !$0.buttonStartsRecording && $0.canControlDictation } ?? false },
       log: { [weak self] in self?.log($0) },
       localVoiceKey: { [weak self] in self?.localDictation.voicePressed() },
       cancelLocalVoice: { [weak self] in self?.localDictation.cancel() })
    private var panel: NSPanel?
    private let dashboard = T1DashboardModel()
    private var nextMeterUpdate: TimeInterval = 0
    private var central: CBCentralManager?
    private var remote: CBPeripheral?
    private var tx: CBCharacteristic?
    private var subscriptions = Set<CBUUID>()
    private var ready = false
    private var recording = false
    private var automaticMic = false
    private var inputClients = Set<AudioObjectID>()
    private var stopInputObserver: (() -> Void)?
    private var timer: Timer?
    private var watchdog: Timer?
    private var started: Date?
    private var lastPacket: Date?
    private var lastKeepalive: Date?
    private var nextReport: TimeInterval = 10
    private var packets = 0
    private var dictationFramesAtStart: UInt64?
    private var dictationOpenRetried = false
    private var releaseReopen: DispatchWorkItem?
    private var recoveredRelease = false
    private var widestGap: TimeInterval = 0
    private var completedTest = false
    private let arguments = Set(CommandLine.arguments.dropFirst())
    private var testMode: Bool { arguments.contains("--test-host-start") || arguments.contains("--test-button-start") }
    private var buttonStartsRecording: Bool {
        arguments.contains("--test-button-start") || (!testMode &&
            UserDefaults.standard.bool(forKey: "VoiceButtonControlsMic") &&
            !T1ProfileStore.shared.isNative(NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
    }
    private var canControlDictation: Bool { inputClients.isEmpty || dictationFramesAtStart != nil }


    func applicationDidFinishLaunching(_ note: Notification) {
        if arguments.contains("--ui-preview") {
            dashboard.ready = true
            dashboard.bluetooth = true
            dashboard.status = "已连接，可开启麦克风"
            dashboard.defaultInput = deviceName
            showPanel()
            return
        }
        if !testMode {
            T1Button.migrateControllerDefaults()
            if !AXIsProcessTrusted() || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                dashboard.page = .setup
            }
        }
        if arguments.contains("--background") {
            // A hidden login launch also hides the dictation HUD. Clear that
            // state without activating the app or opening its settings window.
            DispatchQueue.main.async {
                if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            }
        } else if !testMode {
            showPanel()
        }
        if !testMode {
            log("控制授权：辅助功能=\(AXIsProcessTrusted()) 输入监控=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)")
            controller.setupInput()
            if arguments.contains("--request-controller-access") { controller.requestPermissions() }
        }

        do {
            let route = try sink.open()
            log("音频输出：\(deviceName)（\(route)）")
        } catch {
            setStatus(error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = "T1 Controller 未启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        if !testMode, deviceName == compatibilityInput, #available(macOS 15.0, *) {
            let activity = DefaultInputActivity { [weak self] clients in self?.inputClientsChanged(clients) }
            stopInputObserver = { activity.stop() }
            activity.start()
        }
        setStatus("正在连接 T1")
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.findRemote()
            if !self.testMode { self.controller.setupInput(); self.controller.checkVoice() }
            if self.panel?.isVisible == true { self.refreshDashboard() }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if testMode { log("BLUETOOTH state=\(central.state.rawValue) auth=\(CBManager.authorization.rawValue)") }
        if central.state == .poweredOn {
            findRemote()
        } else {
            resetRemote()
            setStatus(central.state == .unauthorized ? "请在隐私与安全性中允许蓝牙" : "蓝牙尚未就绪")
        }
    }

    private func findRemote() {
        guard let central, central.state == .poweredOn, remote == nil else { return }
        let identifiers = [uuid[0]] + ["180A", "180F", "AE40", "AE00"].map { CBUUID(string: $0) }
        guard let target = central.retrieveConnectedPeripherals(withServices: identifiers)
            .first(where: { $0.name == "T1-Remote" }) else {
            if testMode { log("WAITING_FOR_T1") }
            setStatus("等待 T1 蓝牙连接")
            return
        }
        if testMode { log("CONNECTING") }
        setStatus("正在连接 T1")
        remote = target
        target.delegate = self
        central.connect(target, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if testMode { log("CONNECTED") }
        peripheral.discoverServices([uuid[0]])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetRemote()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetRemote()
        setStatus("T1 已断开，等待重连")
    }

    private func resetRemote() {
        if recording { logSummary("disconnected") }
        releaseReopen?.cancel()
        releaseReopen = nil
        localCapture = false
        if !testMode { controller.remoteDisconnected() }
        watchdog?.invalidate()
        recording = false
        automaticMic = false
        ready = false
        if dictationFramesAtStart != nil {
            dictationFramesAtStart = nil
            if !testMode { controller.microphoneInterrupted() }
        }
        tx = nil
        subscriptions.removeAll()
        remote = nil
        refreshDashboard()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == uuid[0] }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(Array(uuid.dropFirst()), for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        tx = chars.first(where: { $0.uuid == uuid[1] })
        guard tx != nil, chars.count == 3 else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        for characteristic in chars where characteristic.uuid != uuid[1] {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        subscriptions.insert(characteristic.uuid)
        if subscriptions.count == 2 { send([0x0A, 0, 4, 0, 3]) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, let command = data.first else { return }
        if characteristic.uuid == uuid[2] {
            guard recording, releaseReopen == nil, let pcm = T1Audio.decode(data) else { return }
            let now = Date()
            if let lastPacket {
                widestGap = max(widestGap, now.timeIntervalSince(lastPacket))
            } else if testMode || dictationFramesAtStart != nil || automaticMic {
                log("FIRST_FRAME")
            }
            lastPacket = now
            packets += 1
            sink.push(pcm)
            if localCapture { localDictation.receive(pcm) }
            if panel?.isVisible == true, now.timeIntervalSinceReferenceDate >= nextMeterUpdate {
                nextMeterUpdate = now.timeIntervalSinceReferenceDate + 0.10
                let meanSquare = pcm.reduce(0.0) { sum, sample in
                    let amplitude = Double(sample) / 32768
                    return sum + amplitude * amplitude
                } / Double(pcm.count)
                let dB = 10 * log10(max(meanSquare, 1e-9))
                dashboard.level = min(1, max(0, (dB + 58) / 50))
            }
            return
        }
        if testMode || ((dictationFramesAtStart != nil || localCapture) && command != 0x08) {
            log("CTL " + data.map { String(format: "%02x", $0) }.joined())
        }
        switch command {
        case 0x0B:
            ready = data == Data([0x0B, 0, 4, 0, 2, 0, 134, 0, 134])
            setStatus(ready ? idleStatus : "T1 返回了未验证的音频格式")
            if ready {
                if testMode || (!controller.hasHIDInput &&
                    !T1ProfileStore.shared.isNative(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)) {
                    controller.applyVoiceFallbackMapping()
                }
                if !testMode { controller.applyMapping() }
                if !inputClients.isEmpty { inputClientsChanged(inputClients) }
                if testMode {
                    log("READY")
                    if arguments.contains("--test-host-start") && !completedTest { startRecording() }
                }
            }
        case 0x08 where ready && buttonStartsRecording && !completedTest && !automaticMic:
            if recording { stopRecording() } else { startRecording() }
        case 0x08 where ready && !testMode && !controller.hasHIDInput && canControlDictation:
            log("收到 T1 语音请求（蓝牙）")
            controller.voicePressed()
        case 0x00:
            guard recording else { return }
            if data.count >= 2, data[1] == 2, dictationFramesAtStart != nil || localCapture {
                reopenAfterButtonRelease()
            } else {
                finish("remote stop")
            }
        default:
            break
        }
    }

    private func send(_ message: [UInt8]) {
        guard let remote, let tx else { return }
        remote.writeValue(Data(message), for: tx, type: tx.properties.contains(.write) ? .withResponse : .withoutResponse)
    }

    private var idleStatus: String {
        buttonStartsRecording ? "已连接，按 T1 语音键或在窗口开启" : "已连接，可开启麦克风"
    }

    private func changeButtonMode() {
        guard !testMode else { return }
        localDictation.cancel()
        if ready && !recording { setStatus(idleStatus) }
    }

    private func startRecording() {
        guard ready, !recording, !completedTest, !arguments.contains("--ui-preview") else { return }
        recording = true
        recoveredRelease = false
        started = Date()
        lastKeepalive = started
        lastPacket = nil
        nextReport = 10
        packets = 0
        widestGap = 0
        send([0x0C, 0, 2])
        setStatus("麦克风已开启，输出到 \(deviceName)")
        if testMode { log("START \(arguments.contains("--test-host-start") ? "host" : "button")") }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkStream() }
    }

    private func reopenAfterButtonRelease() {
        // Some T1 connections end the stream on physical release even after
        // MIC_OPEN. Keep this toggle session and reopen once the key is up.
        guard !recoveredRelease else { return }
        recoveredRelease = true
        lastPacket = nil
        let reopen = DispatchWorkItem { [weak self] in
            guard let self, self.recording else { return }
            self.releaseReopen = nil
            let now = Date()
            self.started = now
            self.lastKeepalive = now
            self.dictationOpenRetried = false
            if self.dictationFramesAtStart != nil {
                self.dictationFramesAtStart = self.sink.deliveredFrames
            }
            self.log("T1 松手后恢复收音")
            self.send([0x0C, 0, 2])
        }
        releaseReopen = reopen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: reopen)
    }

    private func inputClientsChanged(_ clients: Set<AudioObjectID>) {
        inputClients = clients
        if !clients.isEmpty {
            if localCapture, currentInputName() == compatibilityInput {
                localCapture = false
                automaticMic = true
                localDictation.cancel("其他应用正在使用麦克风")
                return
            }
            guard ready, !recording, currentInputName() == compatibilityInput else { return }
            dictationOpenRetried = false
            startRecording()
            automaticMic = recording
            if automaticMic { log("有 App 正在读取 T1 默认输入，已开启 T1 收音") }
        } else if automaticMic {
            finish("no active T1 input client")
        }
    }

    private func checkStream() {
        guard let started, recording, releaseReopen == nil else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(started)
        if (dictationFramesAtStart != nil || automaticMic || localCapture), lastPacket == nil, elapsed >= 0.7, !dictationOpenRetried {
            dictationOpenRetried = true
            log("尚未收到音频，重试一次开启 T1")
            send([0x0C, 0, 2])
        }
        if now.timeIntervalSince(lastPacket ?? started) > 2 {
            finish(lastPacket == nil ? "no first frame" : "frame timeout")
            return
        }
        if testMode && elapsed >= 160 {
            finish("test completed")
            return
        }
        if lastPacket != nil && !arguments.contains("--no-keepalive"),
           let lastKeepalive, now.timeIntervalSince(lastKeepalive) >= 10 {
            self.lastKeepalive = now
            if testMode { log("KEEPALIVE \(Int(elapsed))s") }
            send([0x0C, 0, 2])
        }
        if testMode && elapsed >= nextReport {
            logSummary("streaming")
            nextReport += 10
        }
    }

    private func stopRecording() { finish("manual stop") }

    private func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private func logSummary(_ state: String) {
        guard testMode, let started else { return }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        let gap = String(format: "%.3f", widestGap)
        log("STREAM \(state) elapsed=\(elapsed)s packets=\(packets) maxGap=\(gap)s")
    }

    private func finish(_ reason: String) {
        guard recording else { return }
        logSummary(reason)
        recording = false
        releaseReopen?.cancel()
        releaseReopen = nil
        completedTest = testMode
        watchdog?.invalidate()
        send([0x0D])
        setStatus(ready ? idleStatus : "等待 T1")
        if localCapture {
            localCapture = false
            localDictation.streamStopped()
        }
        if automaticMic {
            automaticMic = false
            log("按需收音已停止：\(reason)，共 \(packets) 包")
        }
        if dictationFramesAtStart != nil {
            dictationFramesAtStart = nil
            log("听写音频已停止：\(reason)，共 \(packets) 包")
            if !testMode { controller.microphoneInterrupted() }
        }
    }

    private func setStatus(_ status: String) {
        dashboard.status = status
        refreshDashboard()
        if !testMode { log(status) }
    }

    private func refreshDashboard() {
        guard !arguments.contains("--ui-preview") else { return }
        dashboard.ready = ready
        dashboard.recording = recording
        if !recording { dashboard.level = 0 }
        dashboard.defaultInput = currentInputName() ?? "未找到输入"
        dashboard.bluetooth = CBManager.authorization == .allowedAlways
        dashboard.accessibility = AXIsProcessTrusted()
        dashboard.inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func showPanel() {
        refreshDashboard()
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 855, height: 620),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "T1 Controller"
            window.contentMinSize = NSSize(width: 760, height: 530)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
            window.contentView = NSHostingView(rootView: T1Dashboard(
                model: dashboard, audioDevice: deviceName, version: version, profiles: .shared,
                start: { [weak self] in self?.startRecording() },
                stop: { [weak self] in self?.stopRecording() },
                authorize: { [weak self] in
                    guard let self, !self.arguments.contains("--ui-preview") else { return }
                    self.controller.requestPermissions()
                    self.refreshDashboard()
                },
                modeChanged: { [weak self] in self?.changeButtonMode() }))
            window.center()
            panel = window
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        stopInputObserver?()
        stopRecording()
        if !testMode { controller.stop() }
        timer?.invalidate()
        sink.close()
    }
}

if CommandLine.arguments.dropFirst().first == "--check-audio" {
    do {
        let sink = Loopback()
        let route = try sink.open()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        print("Audio route opened: \(deviceName) [\(route)]")
        sink.close()
    } catch {
        print(error.localizedDescription)
        exit(2)
    }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--decode-test" {
    let capture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    var pcm = Data()
    var offset = 0
    while offset + 2 <= capture.count {
        let length = (Int(capture[offset]) << 8) | Int(capture[offset + 1])
        offset += 2
        guard offset + length <= capture.count,
              let samples = T1Audio.decode(capture.subdata(in: offset..<(offset + length))) else { exit(3) }
        pcm.append(samples.withUnsafeBytes { Data($0) })
        offset += length
    }
    guard offset == capture.count, !pcm.isEmpty else { exit(3) }
    FileHandle.standardOutput.write(pcm)
} else {
    let app = NSApplication.shared
    let bridge = Bridge()
    app.delegate = bridge
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(bridge) { app.run() }
}
