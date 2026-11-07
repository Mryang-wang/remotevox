import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Use the property wrapper while command-line Swift lacks the SDK State macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

private struct ShortcutTarget: Identifiable {
    let id = UUID()
    let button: T1Button
    let gesture: T1Gesture
    let profileID: String?
}

struct T1ProfilesView: View {
    @ObservedObject var profiles: T1ProfileStore
    @AppStorage(T1ProfileStore.localDictationEnabledKey) private var localDictationEnabled = false
    @ViewState<String> private var selectedID = ""
    @ViewState<ShortcutTarget?> private var recording = nil
    @ViewState<String?> private var message = nil
    @ViewState<Bool> private var showRemove = false
    @ViewState<Bool> private var showReset = false

    private var profileID: String? { selectedID.isEmpty ? nil : selectedID }
    private var selected: T1AppProfile? { profiles.profile(profileID) }
    private var editable: Bool { selected?.enabled != false && selected?.nativeMode != true && profiles.error == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("编辑配置", selection: $selectedID) {
                        Text("通用设置").tag("")
                        ForEach(profiles.apps) { app in Text(app.name).tag(app.id) }
                    }
                    .frame(maxWidth: 340)
                    Button(action: addApp) { Label("添加 App", systemImage: "plus") }
                        .disabled(profiles.error != nil)
                    if selected != nil {
                        Button(role: .destructive) { showRemove = true } label: {
                            Image(systemName: "minus")
                        }
                        .help("移除此应用配置")
                        .disabled(profiles.error != nil)
                    }
                }
                Label("当前生效  " + profiles.activeName, systemImage: "app.connected.to.app.below.fill")
                    .font(.callout.weight(.medium))
                if !profiles.frontAppName.isEmpty {
                    Text("前台应用  " + profiles.frontAppName).font(.caption).foregroundStyle(.secondary)
                }
                if let profile = selected {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appPath(profile)))
                            .resizable().scaledToFit().frame(width: 32, height: 32)
                        Text(profile.name).font(.headline)
                        Spacer()
                        Toggle("启用配置", isOn: Binding(get: { selected?.enabled ?? false }, set: {
                            profiles.updateApp(profile.id, enabled: $0)
                        })).toggleStyle(.switch).fixedSize()
                    }
                    Toggle("原生模式", isOn: Binding(get: { selected?.nativeMode ?? false }, set: {
                        profiles.updateApp(profile.id, nativeMode: $0)
                    }))
                    .disabled(!profile.enabled || profiles.error != nil)
                    Text(profile.nativeMode
                         ? "此应用前台时使用遥控器原生操作。电源键和已打开的系统 App 菜单使用系统控制。"
                         : "切换到此应用时自动使用本页配置。未单独设置的按键继承通用设置。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("通用设置用于所有未配置的应用。单击、双击和长按可分别设置，修改即时生效。")
                        .font(.callout).foregroundStyle(.secondary)
                    if #available(macOS 26.0, *) {
                        Toggle("语音键使用本机听写（测试）", isOn: $localDictationEnabled)
                        Text("在普通应用的文本框内按一下语音键开始，再按一下输入。Codex 使用专用听写。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = profiles.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))

            ForEach(T1Button.allCases, id: \.self) { button in
                VStack(alignment: .leading, spacing: 10) {
                    Label(button.title, systemImage: icon(button)).font(.headline)
                    if button == .back {
                        Text("飞鼠模式下默认是鼠标右键。在 Codex 查找框、系统 App 菜单或切换器中，返回键可关闭当前界面。设置自定义动作后按本页映射执行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(T1Gesture.allCases, id: \.self) { gesture in
                            bindingEditor(button, gesture)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.secondary.opacity(0.16)) }
                .disabled(!editable)
            }

            Text("方向键和 OK 默认使用原生动作。飞鼠模式下的 OK 保留点击和拖选。遥控器背面发出同一键码时，会使用同一映射。侧面音量键使用原生行为。")
                .font(.callout).foregroundStyle(.secondary)
            Text("Codex 的语音键负责听写开始、结束和双击作废。电源键用于锁屏、熄屏及关机确认。")
                .font(.callout).foregroundStyle(.secondary)
            Button(profileID == nil ? "恢复通用默认设置" : "恢复继承通用设置") { showReset = true }
                .disabled(!editable)
        }
        .sheet(item: $recording, onDismiss: { profiles.recordingShortcut = false }) { target in
            T1ShortcutRecorder(recorded: { shortcut in
                profiles.setBinding(T1Binding(.customShortcut, shortcut: shortcut),
                    button: target.button, gesture: target.gesture, profileID: target.profileID)
                finishRecording()
            }, cancel: finishRecording)
        }
        .confirmationDialog("移除此应用配置？", isPresented: $showRemove) {
            Button("移除配置", role: .destructive) {
                if let profileID { profiles.removeApp(profileID) }
                selectedID = ""
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("恢复此配置的按键设置？", isPresented: $showReset) {
            Button("恢复", role: .destructive) { profiles.reset(profileID) }
            Button("取消", role: .cancel) {}
        }
        .alert("无法添加应用", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .onDisappear { profiles.recordingShortcut = false }
    }

    private func bindingEditor(_ button: T1Button, _ gesture: T1Gesture) -> some View {
        let configured = profiles.binding(button, gesture, in: profileID)
        return VStack(alignment: .leading, spacing: 6) {
            Text(gesture.title).font(.caption).foregroundStyle(.secondary)
            Picker(gesture.title, selection: Binding(get: {
                profiles.binding(button, gesture, in: profileID).action
            }, set: { action in
                if action == .customShortcut { beginRecording(button, gesture) }
                else { profiles.setBinding(T1Binding(action), button: button, gesture: gesture, profileID: profileID) }
            })) {
                ForEach(T1ButtonAction.allCases.filter {
                    ($0 != .native || (button.navigationKeyCode != nil && gesture == .single)) &&
                    (profileID != nil || $0 != .inherit)
                }, id: \.self) { action in
                    Text(button == .back && gesture == .single && action == .none ? "默认返回" : action.definition.title)
                        .tag(action)
                }
            }
            .labelsHidden()
            .accessibilityLabel(button.title + " " + gesture.title)
            if configured.action == .customShortcut {
                Button(configured.shortcut?.label ?? "录制快捷键") {
                    beginRecording(button, gesture)
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            } else if configured.action == .inherit {
                Text("通用为 " + profiles.binding(button, gesture, in: nil).action.definition.title)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "添加应用配置"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { selectedID = try profiles.addApp(url) }
            catch { message = "请选择有效的 macOS 应用。" }
        }
    }

    private func beginRecording(_ button: T1Button, _ gesture: T1Gesture) {
        profiles.recordingShortcut = true
        recording = ShortcutTarget(button: button, gesture: gesture, profileID: profileID)
    }

    private func finishRecording() {
        recording = nil
        profiles.recordingShortcut = false
    }

    private func appPath(_ profile: T1AppProfile) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.id)?.path ?? profile.path
    }

    private func icon(_ button: T1Button) -> String {
        switch button {
        case .back: "arrow.uturn.backward"
        case .menu: "line.3.horizontal"
        case .home: "house"
        case .mute: "speaker.slash"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .ok: "checkmark.circle"
        }
    }
}
