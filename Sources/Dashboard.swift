import AppKit
import ServiceManagement
import SwiftUI

private typealias DashboardState<Value> = SwiftUI.State<Value>

enum T1DashboardPage: String, CaseIterable, Identifiable {
    case overview, mapping, microphone, setup
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "设备概览"
        case .mapping: "按键映射"
        case .microphone: "麦克风"
        case .setup: "权限与启动"
        }
    }
    var icon: String {
        switch self {
        case .overview: "dot.radiowaves.left.and.right"
        case .mapping: "keyboard"
        case .microphone: "waveform"
        case .setup: "gearshape"
        }
    }
}

final class T1DashboardModel: ObservableObject {
    @Published var status = "正在连接 T1"
    @Published var ready = false
    @Published var recording = false
    @Published var level = 0.0
    @Published var defaultInput = "未找到输入"
    @Published var bluetooth = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var transport = T1Transport.bluetooth
    @Published var receiverAttached = false
    @Published var receiverActive = false
    @Published var battery: Int?
    @Published var page: T1DashboardPage = .overview
}

struct T1Dashboard: View {
    private static let sidebarIcon = Bundle.main.url(forResource: "T1DashboardIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    @ObservedObject var model: T1DashboardModel
    let audioDevice: String
    let version: String
    let profiles: T1ProfileStore
    let start: () -> Void
    let stop: () -> Void
    let authorize: () -> Void
    let modeChanged: () -> Void
    var connectionModeChanged: () -> Void = {}
    @AppStorage("VoiceButtonControlsMic") private var micOnly = false
    @AppStorage(T1ConnectionMode.storageKey) private var connectionMode = T1ConnectionMode.automatic
    @DashboardState<SMAppService.Status> private var loginStatus = .notRegistered
    @DashboardState<String?> private var setupMessage = nil
    @DashboardState<Bool> private var preparingModel = false

    private var loginService: SMAppService {
        .agent(plistName: "local.codex.t1microphone.background.plist")
    }

    private let accent = Color(red: 0.10, green: 0.50, blue: 0.66)
    private var primaryStatus: String {
        if model.recording { return "正在收音" }
        if model.transport == .receiver && model.receiverAttached {
            return model.receiverActive ? "已收到 2.4G 按键" : "等待 2.4G 按键"
        }
        return model.ready ? "已连接 · 待命" : "等待连接"
    }
    private var isDefault: Bool { model.defaultInput == audioDevice }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.page.title).font(.system(size: 29, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    switch model.page {
                    case .overview: overview
                    case .mapping: mapping
                    case .microphone: microphone
                    case .setup: setup
                    }
                }
                .frame(maxWidth: 740, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 530)
        .tint(accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: Self.sidebarIcon ?? NSApplication.shared.applicationIconImage)
                    .interpolation(.high)
                    .resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("RemoteVox").font(.headline)
                    Text("遥控器与语音").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                ForEach(T1DashboardPage.allCases) { item in
                    Button {
                        model.page = item
                    } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 13, weight: model.page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .background(model.page == item ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.page == item ? .isSelected : [])
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: model.recording ? "mic.fill" : "circle.fill")
                    .foregroundStyle(model.ready ? accent : Color.secondary)
                Text(primaryStatus).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            Text("版本 \(version)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 17).padding(.top, 20).padding(.bottom, 16)
        .frame(width: 184)
        .background(.regularMaterial)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.transport == .bluetooth ? "蓝牙遥控器" : "2.4G 遥控器")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                    Text("T1 Remote").font(.system(size: 34, weight: .semibold))
                    Label(primaryStatus, systemImage: model.recording ? "waveform" : "circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.16), in: Capsule())
                    if let battery = model.battery {
                        Label("电量 \(battery)%", systemImage: "battery.50percent").font(.callout)
                    }
                }
                Spacer()
                Image(systemName: "appletvremote.gen4")
                    .font(.system(size: 85, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.79))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(LinearGradient(colors: [Color(red: 0.07, green: 0.21, blue: 0.30),
                                                  Color(red: 0.10, green: 0.45, blue: 0.51)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18))
            card("连接方式", icon: "antenna.radiowaves.left.and.right") {
                Picker("连接偏好", selection: $connectionMode) {
                    ForEach(T1ConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: connectionMode) { _, _ in connectionModeChanged() }
                if model.receiverAttached && model.transport == .bluetooth {
                    Text("2.4G 接收器已插入，当前选择蓝牙。").font(.callout).foregroundStyle(.secondary)
                } else if model.transport == .receiver {
                    Text("请在遥控器上切到 2.4G。此模式暂未读取电量。").font(.callout).foregroundStyle(.secondary)
                }
            }
            card("当前输入", icon: "mic") {
                Text(model.defaultInput).font(.callout.weight(.medium))
                Text(isDefault ? "App 读取 T1 时自动收音，结束后飞鼠恢复。" : "选择 T1 为默认输入后，按需收音才会启用。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("声音输入设置") { openSettings("Sound-Settings.extension?input") }
            }
            card("快捷用法", icon: "cursorarrow.rays") {
                Text("飞鼠模式下，按住 OK 从起点拖到终点后松开。双击三横线复制，长按粘贴。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("单击三横线打开系统 App 菜单。主页单击显示桌面，双击呼出系统 App 切换器。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("查看按键映射") { model.page = .mapping }
            }
            if !model.accessibility || !model.inputMonitoring {
                card("按键权限待完成", icon: "lock.shield") {
                    Text("开启辅助功能和输入监控后，即可使用自定义按键。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("查看权限") { model.page = .setup }
                }
            }
        }
    }

    private var mapping: some View {
        T1ProfilesView(profiles: profiles)
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("音频与电平", icon: "waveform") {
                Text(model.status).font(.callout)
                ProgressView(value: model.level).progressViewStyle(.linear)
                    .accessibilityLabel("输入电平")
                LabeledContent("系统默认输入", value: model.defaultInput)
                LabeledContent("T1 音频设备", value: audioDevice)
                HStack {
                    Button("开启麦克风测试", action: start)
                        .buttonStyle(.borderedProminent).disabled(!model.ready || model.recording)
                    Button("停止收音", action: stop).disabled(!model.recording)
                    Button("声音输入设置") { openSettings("Sound-Settings.extension?input") }
                }
            }
            card("语音键", icon: "mic.circle") {
                Toggle("用 T1 语音键直接开关麦克风", isOn: $micOnly)
                    .onChange(of: micOnly) { _, _ in modeChanged() }
                Text("默认使用 Codex 听写。单击开始或结束，录音中双击作废。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("系统授权", icon: "lock.shield") {
                permission("蓝牙", note: "连接遥控器并接收音频", enabled: model.bluetooth,
                           pane: "com.apple.preference.security?Privacy_Bluetooth")
                Divider()
                permission("辅助功能", note: "执行自定义快捷键", enabled: model.accessibility,
                           pane: "com.apple.preference.security?Privacy_Accessibility")
                Divider()
                permission("输入监控", note: "识别遥控器的实体按键", enabled: model.inputMonitoring,
                           pane: "com.apple.preference.security?Privacy_ListenEvent")
                Button("检查并请求控制权限", action: authorize)
                    .disabled(model.accessibility && model.inputMonitoring)
            }
            card("声音输入和本机听写", icon: "waveform") {
                Text("要在 Codex、Siri 和通话中使用 T1，请在系统声音输入中选择 T1 USB-Compatible Mic。普通 App 的本机听写需要苹果的简体中文模型。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("打开声音输入") { openSettings("Sound-Settings.extension?input") }
                    if #available(macOS 26.0, *) {
                        Button(preparingModel ? "正在准备…" : "准备简体中文模型") {
                            preparingModel = true
                            Task { @MainActor in
                                defer { preparingModel = false }
                                do {
                                    try await T1LocalTranscriber.prepareModel()
                                    setupMessage = "简体中文模型已就绪。"
                                } catch { setupMessage = "无法准备中文模型。\(error.localizedDescription)" }
                            }
                        }
                        .disabled(preparingModel)
                    }
                }
            }
            card("后台运行", icon: "moon.zzz") {
                Text("开启后登录时在后台待命。双击 RemoteVox 打开此窗口。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if loginStatus != .notFound {
                        Button(loginStatus == .enabled ? "关闭登录启动" :
                                loginStatus == .requiresApproval ? "确认登录启动" : "开启登录启动") {
                            changeLoginItem()
                        }
                    }
                    Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    Button("退出 RemoteVox") { NSApplication.shared.terminate(nil) }
                }
            }
            if let setupMessage { Text(setupMessage).font(.callout).foregroundStyle(.secondary) }
        }
        .onAppear { loginStatus = loginService.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = loginService.status
        }
    }

    private func changeLoginItem() {
        if loginStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if loginStatus == .enabled { try loginService.unregister() }
            else { try loginService.register() }
            loginStatus = loginService.status
            if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            setupMessage = nil
        } catch {
            setupMessage = "无法更新登录启动。\(error.localizedDescription)"
        }
    }

    private func permission(_ title: String, note: String, enabled: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: enabled ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(enabled ? accent : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(enabled ? "已授权" : "待授权").font(.caption).foregroundStyle(.secondary)
            Button("系统设置") { openSettings(pane) }
        }
    }

    private func card<Content: View>(_ title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.secondary.opacity(0.16)) }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
