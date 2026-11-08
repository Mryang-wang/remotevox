import AppKit
import ApplicationServices
import AVFoundation
import Speech

enum T1DictationLanguage: String, CaseIterable {
    static let storageKey = "T1LocalDictationLanguage"

    case simplifiedChinese = "zh-Hans-CN"
    case englishUS = "en-US"
    case mixedChineseEnglish = "zh-en"

    var title: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .englishUS: "English（美国）"
        case .mixedChineseEnglish: "中英混合"
        }
    }

    static var current: Self {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .simplifiedChinese
    }
}

@available(macOS 26.0, *)
enum T1LocalTranscriber {
    enum Failure: LocalizedError {
        case unsupported(T1DictationLanguage), model(T1DictationLanguage), format
        var errorDescription: String? {
            switch self {
            case .unsupported(let language): "这台 Mac 无法使用\(language.title)本机听写"
            case .model(let language): "请先在「权限与启动」下载\(language.title)模型"
            case .format: "语音格式转换失败"
            }
        }
    }

    private static func locale(for language: T1DictationLanguage) async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue))
        else { throw Failure.unsupported(language) }
        return locale
    }

    static func isModelInstalled(for language: T1DictationLanguage) async throws -> Bool {
        if language == .mixedChineseEnglish { return await T1MixedDictation.shared.isInstalled() }
        let locale = try await locale(for: language)
        return await SpeechTranscriber.installedLocales.contains(locale)
    }

    static func prepareModel(for language: T1DictationLanguage) async throws {
        if language == .mixedChineseEnglish {
            try await T1MixedDictation.shared.prepare()
            return
        }
        let locale = try await locale(for: language)
        if await SpeechTranscriber.installedLocales.contains(locale) { return }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard await SpeechTranscriber.installedLocales.contains(locale) else { throw Failure.model(language) }
    }

    static func transcribe(_ samples: [Int16], language: T1DictationLanguage) async throws -> String {
        if language == .mixedChineseEnglish { return try await T1MixedDictation.shared.transcribe(samples) }
        let locale = try await locale(for: language)
        guard await SpeechTranscriber.installedLocales.contains(locale) else { throw Failure.model(language) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                  channels: 1, interleaved: false),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                  considering: sourceFormat),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.int16ChannelData?[0] else { throw Failure.format }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { channel.update(from: base, count: buffer.count) }
        }
        let input = try convert(source, to: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await analyzer.prepareToAnalyze(in: format)
                let sequence = AsyncStream<AnalyzerInput> { stream in
                    stream.yield(AnalyzerInput(buffer: input))
                    stream.finish()
                }
                try await analyzer.start(inputSequence: sequence)
                async let transcript = collect(transcriber)
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
                return try await transcript
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func collect(_ transcriber: SpeechTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == format { return source }
        let frames = ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)
        guard let converter = AVAudioConverter(from: source.format, to: format),
              let destination = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames) + 512) else { throw Failure.format }
        var error: NSError?
        var sent = false
        let status = converter.convert(to: destination, error: &error) { _, inputStatus in
            if sent {
                inputStatus.pointee = .endOfStream
                return nil
            }
            sent = true
            inputStatus.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard status != .error, destination.frameLength > 0 else { throw Failure.format }
        return destination
    }
}

final class T1LocalDictation {
    private struct Target {
        let pid: pid_t
        let window: AXUIElement
        let field: AXUIElement
        let selection: CFTypeRef?

        static func focused() -> Target? {
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.apple.loginwindow" else {
                return nil
            }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            guard let window = element(application, kAXFocusedWindowAttribute),
                  let field = element(application, kAXFocusedUIElementAttribute),
                  let role = value(field, kAXRoleAttribute) as? String,
                  [kAXTextFieldRole, kAXTextAreaRole].contains(role),
                  value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success,
                  settable.boolValue else { return nil }
            return Target(pid: app.processIdentifier, window: window, field: field,
                          selection: value(field, kAXSelectedTextRangeAttribute))
        }

        func isCurrent() -> Bool {
            guard let current = Self.focused(), pid == current.pid,
                  CFEqual(window, current.window), CFEqual(field, current.field) else { return false }
            if let selection, let currentSelection = current.selection {
                return CFEqual(selection, currentSelection)
            }
            return selection == nil && current.selection == nil
        }

        private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }

        private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(result, to: AXUIElement.self)
        }
    }

    private let openMic: () -> Bool
    private let closeMic: () -> Void
    private let log: (String) -> Void
    private var target: Target?
    private var transition: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var samples: [Int16] = []
    private var capturing = false
    private var captureLanguage = T1DictationLanguage.simplifiedChinese
    private var panel: NSPanel?
    private var noticeLabel: NSTextField?
    private var waveform: T1DictationWaveform?
    private var hideNotice: DispatchWorkItem?

    init(openMic: @escaping () -> Bool, closeMic: @escaping () -> Void, log: @escaping (String) -> Void) {
        self.openMic = openMic
        self.closeMic = closeMic
        self.log = log
    }

    func voicePressed() {
        guard task == nil, transition == nil else { return }
        if capturing {
            let finish = DispatchWorkItem { [weak self] in self?.finish() }
            transition = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: finish)
        } else {
            target = Target.focused()
            let start = DispatchWorkItem { [weak self] in self?.begin() }
            transition = start
            // The firmware sends a short HID pulse even when the button stays held.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: start)
        }
    }

    func streamStopped() {
        if capturing, transition != nil { finish() }
        else { cancel("T1 收音已中断，请重试") }
    }

    private func begin() {
        transition = nil
        guard target?.isCurrent() == true else {
            cancel("请先把光标放在普通文本框中")
            return
        }
        guard openMic() else { cancel("T1 未连接或麦克风正在使用"); return }
        captureLanguage = T1DictationLanguage.current
        capturing = true
        show("准备收音…", recording: true)
        waveform?.reset()
        log("本机听写开始收音（\(captureLanguage.title)）")
        let limit = DispatchWorkItem { [weak self] in self?.cancel("听写已超时，请重试") }
        timeout = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: limit)
    }

    func receive(_ pcm: [Int16]) {
        guard capturing else { return }
        if samples.isEmpty {
            show("可以说话，再按一次输入", recording: true)
            log("本机听写收到首帧")
        }
        waveform?.append(pcm)
        samples.append(contentsOf: pcm)
    }

    func cancel(_ message: String? = nil) {
        let active = capturing || transition != nil || task != nil
        transition?.cancel()
        transition = nil
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        target = nil
        samples.removeAll()
        if capturing {
            capturing = false
            closeMic()
        }
        if let message { notify(message) }
        else if active { panel?.orderOut(nil) }
    }

    private func finish() {
        transition?.cancel()
        transition = nil
        timeout?.cancel()
        timeout = nil
        capturing = false
        closeMic()
        let pcm = samples
        samples.removeAll()
        guard let target, target.isCurrent() else { cancel("输入位置已切换"); return }
        guard pcm.count >= 4_000 else { cancel("收音太短，请重试"); return }
        guard #available(macOS 26.0, *) else { cancel("本机识别需要 macOS 26"); return }
        let language = captureLanguage
        show("正在识别…")
        log("本机听写收到 \(pcm.count) 帧，开始识别")
        task = Task { @MainActor [weak self] in
            do {
                let text = try await T1LocalTranscriber.transcribe(pcm, language: language)
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                self.target = nil
                guard !text.isEmpty else { self.notify("未识别到文字"); return }
                guard target.isCurrent() else { self.notify("输入位置已切换"); return }
                let line = text.components(separatedBy: .newlines).joined(separator: " ")
                guard AXUIElementSetAttributeValue(target.field, kAXSelectedTextAttribute as CFString,
                    line as CFString) == .success else { self.notify("此输入框无法写入"); return }
                self.log("本机听写已输入 \(line.count) 字")
                self.panel?.orderOut(nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                self.target = nil
                self.log("本机听写识别失败：\(error.localizedDescription)")
                let message = (error as? T1LocalTranscriber.Failure)?.errorDescription ??
                    (error as? T1MixedDictation.Failure)?.errorDescription
                self.notify(message ?? "本机识别失败，请重试")
            }
        }
    }

    private func show(_ message: String, recording: Bool = false) {
        hideNotice?.cancel()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 66),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.textColor = .white
            label.font = .systemFont(ofSize: 13, weight: .medium)
            let waveform = T1DictationWaveform()
            let stack = NSStackView(views: [waveform, label])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 5
            stack.detachesHiddenViews = true
            let background = NSView()
            background.wantsLayer = true
            background.layer?.cornerRadius = 13
            background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
            stack.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
                waveform.widthAnchor.constraint(equalToConstant: 218),
                waveform.heightAnchor.constraint(equalToConstant: 26)
            ])
            panel.contentView = background
            self.panel = panel
            self.noticeLabel = label
            self.waveform = waveform
        }
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        noticeLabel?.stringValue = message
        waveform?.isHidden = !recording
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                    y: screen.visibleFrame.minY + 65))
        panel.orderFrontRegardless()
    }

    private func notify(_ message: String) {
        log("本机听写：\(message)")
        show(message)
        let hide = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideNotice = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
    }
}

private final class T1DictationWaveform: NSView {
    private let quietLimit = 5
    private var levels = [CGFloat](repeating: 0, count: 34)
    private var power = 0.0
    private var frames = 0
    private var quietBuckets = 5

    func reset() {
        levels = [CGFloat](repeating: 0, count: levels.count)
        power = 0
        frames = 0
        quietBuckets = quietLimit
        needsDisplay = true
    }

    func append(_ samples: [Int16]) {
        for sample in samples {
            let normalized = Double(sample) / 32768
            power += normalized * normalized
            frames += 1
            // Advance every 48 ms at the T1 stream's 16 kHz sample rate.
            if frames == 768 {
                let dB = 10 * log10(max(power / Double(frames), 1e-9))
                updateLevel(dB)
                power = 0
                frames = 0
            }
        }
    }

    private func updateLevel(_ dB: Double) {
        let silenceFloor = -51.0
        if dB > silenceFloor {
            quietBuckets = 0
        } else {
            guard quietBuckets < quietLimit else { return }
            quietBuckets += 1
        }
        if quietBuckets == quietLimit {
            levels = [CGFloat](repeating: 0, count: levels.count)
        } else {
            levels.removeFirst()
            levels.append(CGFloat(min(1, max(0, (dB - silenceFloor) / 38))))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let pitch = bounds.width / CGFloat(levels.count)
        let barWidth: CGFloat = 3
        let bars = NSBezierPath()
        for (index, level) in levels.enumerated() {
            let height = barWidth + level * (bounds.height - barWidth)
            let x = (CGFloat(index) + 0.5) * pitch - barWidth / 2
            let rect = NSRect(x: x, y: bounds.midY - height / 2, width: barWidth, height: height)
            bars.appendRoundedRect(rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        }
        NSColor.white.withAlphaComponent(0.9).setFill()
        bars.fill()
    }
}
