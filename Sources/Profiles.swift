import AppKit
import Foundation

struct T1Shortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt64
    let label: String

    var valid: Bool {
        let allowed: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        return keyCode <= 127 && modifiers & ~allowed.rawValue == 0 && !label.isEmpty
    }
}

struct T1Binding: Codable, Equatable {
    var action: T1ButtonAction
    var shortcut: T1Shortcut?

    init(_ action: T1ButtonAction, shortcut: T1Shortcut? = nil) {
        self.action = action
        self.shortcut = shortcut
    }
}

struct T1AppProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var path: String
    var enabled = true
    var nativeMode = false
    var bindings: [String: T1Binding] = [:]
}

struct T1ProfileDocument: Codable {
    var version = 1
    var general: [String: T1Binding] = [:]
    var apps: [T1AppProfile] = []
}

final class T1ProfileStore: ObservableObject {
    static let localDictationEnabledKey = "T1LocalDictationEnabled"
    static let shared = T1ProfileStore()
    static let changed = Notification.Name("T1ProfilesChanged")
    static let storageKey = "T1AppProfilesV1"

    @Published private(set) var document: T1ProfileDocument
    @Published private(set) var frontAppID: String?
    @Published private(set) var frontAppName = ""
    @Published private(set) var error: String?
    @Published var recordingShortcut = false {
        didSet { NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    private let defaults: UserDefaults
    private var workspaceObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, observeApps: Bool = true) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                let saved = try JSONDecoder().decode(T1ProfileDocument.self, from: data)
                guard saved.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                document = saved
            } catch {
                document = T1ProfileDocument()
                self.error = "应用配置读取失败，原数据已保留。"
            }
        } else {
            T1Button.migrateControllerDefaults(in: defaults)
            var migrated = T1ProfileDocument()
            let old = defaults.dictionary(forKey: T1Button.legacySettingsKey) ?? [:]
            for (key, raw) in old {
                if let raw = raw as? String, let action = T1ButtonAction(rawValue: raw) {
                    migrated.general[key] = T1Binding(action)
                }
            }
            document = migrated
            defaults.set(try? JSONEncoder().encode(migrated), forKey: Self.storageKey)
        }
        if observeApps {
            refreshFrontApp()
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.frontAppID = app.bundleIdentifier
                self?.frontAppName = app.localizedName ?? ""
            }
        }
    }

    deinit {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    var apps: [T1AppProfile] { document.apps }
    var activeName: String {
        guard let id = frontAppID, let profile = profile(id), profile.enabled else { return "通用设置" }
        return profile.name + (profile.nativeMode ? " · 原生模式" : "")
    }

    func profile(_ id: String?) -> T1AppProfile? {
        document.apps.first { $0.id == id }
    }

    func binding(_ button: T1Button, _ gesture: T1Gesture, in profileID: String?) -> T1Binding {
        if let profile = profile(profileID) {
            return profile.bindings[button.key(gesture)] ?? T1Binding(.inherit)
        }
        return document.general[button.key(gesture)] ?? T1Binding(button.defaultAction(gesture))
    }

    func effective(_ button: T1Button, _ gesture: T1Gesture, appID: String?) -> T1Binding {
        if let profile = profile(appID), profile.enabled {
            if profile.nativeMode { return T1Binding(.native) }
            let configured = binding(button, gesture, in: profile.id)
            if configured.action != .inherit { return configured }
        }
        return binding(button, gesture, in: nil)
    }

    func isNative(_ appID: String?) -> Bool {
        guard let profile = profile(appID) else { return false }
        return profile.enabled && profile.nativeMode
    }

    func customizesNavigation(_ button: T1Button, in appID: String?) -> Bool {
        guard button.navigationKeyCode != nil, !isNative(appID) else { return false }
        return effective(button, .single, appID: appID).action != .native ||
            effective(button, .double, appID: appID).action != .none ||
            effective(button, .hold, appID: appID).action != .none
    }

    func setBinding(_ value: T1Binding, button: T1Button, gesture: T1Gesture, profileID: String?) {
        var updated = document
        if let profileID {
            guard let index = updated.apps.firstIndex(where: { $0.id == profileID }) else { return }
            updated.apps[index].bindings[button.key(gesture)] = value
        } else {
            updated.general[button.key(gesture)] = value
        }
        save(updated)
    }

    @discardableResult
    func addApp(_ url: URL) throws -> String {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        var updated = document
        if let index = updated.apps.firstIndex(where: { $0.id == id }) {
            updated.apps[index].name = name
            updated.apps[index].path = url.path
        } else {
            updated.apps.append(T1AppProfile(id: id, name: name, path: url.path))
        }
        updated.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save(updated)
        return id
    }

    func updateApp(_ id: String, enabled: Bool? = nil, nativeMode: Bool? = nil) {
        var updated = document
        guard let index = updated.apps.firstIndex(where: { $0.id == id }) else { return }
        if let enabled { updated.apps[index].enabled = enabled }
        if let nativeMode { updated.apps[index].nativeMode = nativeMode }
        save(updated)
    }

    func removeApp(_ id: String) {
        var updated = document
        updated.apps.removeAll { $0.id == id }
        save(updated)
    }

    func reset(_ profileID: String?) {
        var updated = document
        if let profileID {
            guard let index = updated.apps.firstIndex(where: { $0.id == profileID }) else { return }
            updated.apps[index].bindings = [:]
        } else {
            updated.general = [:]
        }
        save(updated)
    }

    private func save(_ value: T1ProfileDocument) {
        guard error == nil else { return }
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: Self.storageKey)
            document = value
            NotificationCenter.default.post(name: Self.changed, object: self)
        } catch {
            self.error = "配置未能保存，请重新打开设置后再试。"
        }
    }

    private func refreshFrontApp() {
        let app = NSWorkspace.shared.frontmostApplication
        frontAppID = app?.bundleIdentifier
        frontAppName = app?.localizedName ?? ""
    }

}
