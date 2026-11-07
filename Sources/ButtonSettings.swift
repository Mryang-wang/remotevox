import AppKit

enum T1ConnectionMode: String, CaseIterable {
    static let storageKey = "T1ConnectionMode"
    case automatic, bluetooth, receiver

    var title: String {
        switch self {
        case .automatic: "自动（蓝牙优先）"
        case .bluetooth: "蓝牙"
        case .receiver: "2.4G"
        }
    }
}

enum T1Transport: Equatable {
    case bluetooth, receiver
}
import ApplicationServices

enum T1Gesture: String, CaseIterable, Codable {
    case single, double, hold

    var title: String {
        switch self {
        case .single: "单击"
        case .double: "双击"
        case .hold: "长按"
        }
    }
}

enum T1ButtonAction: String, CaseIterable, Codable {
    case none, inherit, native, customShortcut, escape, mute, playPause, nextTrack, previousTrack, rightClick
    case activateChatGPT, right, left, tab, backTab
    case appsMenu, runningApps, showDesktop
    case copy, paste, selectAll, undo, redo
    case sidebar, findInChat, bottomPanel, keyboardShortcuts, codexMode, newChat, codexSendOrStop

    static let codexAppID = "com.openai.codex"

    var definition: (title: String, key: CGKeyCode?, modifiers: CGEventFlags, global: Bool) {
        switch self {
        case .none: ("无操作", nil, [], true)
        case .inherit: ("继承通用设置", nil, [], true)
        case .native: ("使用原生按键", nil, [], true)
        case .customShortcut: ("自定义快捷键", nil, [], true)
        case .escape: ("Esc／返回", 53, [], true)
        case .mute: ("静音／取消静音", nil, [], true)
        case .playPause: ("播放／暂停", nil, [], true)
        case .nextTrack: ("下一首", nil, [], true)
        case .previousTrack: ("上一首", nil, [], true)
        case .rightClick: ("鼠标右键", nil, [], true)
        case .activateChatGPT: ("打开 ChatGPT", nil, [], true)
        case .appsMenu: ("打开系统 App 菜单", nil, [], true)
        case .runningApps: ("系统 App 切换器 ⌘Tab", nil, [], true)
        case .showDesktop: ("显示桌面", nil, [], true)
        case .right: ("右方向键 →", 124, [], false)
        case .left: ("左方向键 ←", 123, [], false)
        case .tab: ("Tab", 48, [], false)
        case .backTab: ("Shift+Tab", 48, .maskShift, false)
        case .copy: ("复制 ⌘C", 8, .maskCommand, true)
        case .paste: ("粘贴 ⌘V", 9, .maskCommand, true)
        case .selectAll: ("全选 ⌘A", 0, .maskCommand, true)
        case .undo: ("撤销 ⌘Z", 6, .maskCommand, true)
        case .redo: ("重做 ⌘⇧Z", 6, [.maskCommand, .maskShift], true)
        case .sidebar: ("Codex 开合侧栏", 1, [.maskCommand, .maskShift], false)
        case .findInChat: ("Codex 对话内查找", 3, .maskCommand, false)
        case .bottomPanel: ("开合 Codex 底部面板", 38, .maskCommand, false)
        case .keyboardShortcuts: ("打开快捷键表", 44, .maskCommand, false)
        case .codexMode: ("切换到 Codex", 20, .maskControl, true)
        case .newChat: ("Codex 新建对话", 45, .maskCommand, true)
        case .codexSendOrStop: ("Codex 发送／停止／继续", nil, [], false)
        }
    }
}

enum T1Button: UInt32, CaseIterable {
    case back = 0xC0224, menu = 0x70065, home = 0xC0223, mute = 0xC00E2
    case up = 0x70052, down = 0x70051, left = 0x70050, right = 0x7004F, ok = 0x70028

    static let legacySettingsKey = "T1ButtonActions"

    var title: String {
        switch self {
        case .back: "返回键"
        case .menu: "三横线"
        case .home: "主页键"
        case .mute: "静音键"
        case .up: "上方向键"
        case .down: "下方向键"
        case .left: "左方向键"
        case .right: "右方向键"
        case .ok: "OK 键"
        }
    }

    var navigationKeyCode: CGKeyCode? {
        switch self {
        case .up: 126
        case .down: 125
        case .left: 123
        case .right: 124
        case .ok: 36
        default: nil
        }
    }

    func key(_ gesture: T1Gesture) -> String { "\(rawValue).\(gesture.rawValue)" }

    func defaultAction(_ gesture: T1Gesture) -> T1ButtonAction {
        if navigationKeyCode != nil, gesture == .single { return .native }
        switch (self, gesture) {
        case (.mute, .single): return .mute
        case (.menu, .single): return .appsMenu
        case (.menu, .double): return .copy
        case (.menu, .hold): return .paste
        case (.home, .single): return .showDesktop
        case (.home, .double): return .runningApps
        case (.home, .hold): return .newChat
        default: return .none
        }
    }

    static func migrateControllerDefaults(in defaults: UserDefaults = .standard) {
        var actions = defaults.dictionary(forKey: legacySettingsKey) ?? [:]
        if !defaults.bool(forKey: "T1ControllerPresetApplied") {
            for (button, gesture): (Self, T1Gesture) in [(.back, .single), (.home, .hold), (.menu, .double), (.menu, .hold)] {
                actions.removeValue(forKey: button.key(gesture))
            }
            defaults.set(true, forKey: "T1ControllerPresetApplied")
        }
        if !defaults.bool(forKey: "T1AppPickerPresetApplied") {
            for (button, gesture): (Self, T1Gesture) in [(.home, .single), (.home, .double), (.menu, .single)] {
                actions.removeValue(forKey: button.key(gesture))
            }
            defaults.set(true, forKey: "T1AppPickerPresetApplied")
        }
        defaults.set(actions, forKey: legacySettingsKey)
    }
}
