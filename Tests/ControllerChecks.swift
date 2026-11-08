import AppKit
import ApplicationServices
import SwiftUI

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

func wait(_ time: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: time)) }

let isolatedName = "local.codex.t1.controller.tests." + UUID().uuidString
guard let prefs = UserDefaults(suiteName: isolatedName) else { exit(1) }
defer { prefs.removePersistentDomain(forName: isolatedName) }
prefs.set(true, forKey: "T1ControllerPresetApplied")
prefs.set(["\(T1Button.back.rawValue).double": "left", "\(T1Button.home.rawValue).double": "sidebar",
           "\(T1Button.menu.rawValue).single": "findInChat"], forKey: "T1ButtonActions")
T1Button.migrateControllerDefaults(in: prefs)
let migrated = prefs.dictionary(forKey: "T1ButtonActions")
require(migrated?.count == 1 && migrated?["\(T1Button.back.rawValue).double"] as? String == "left",
        "Migration must replace only explicitly requested bindings")
prefs.set(["\(T1Button.back.rawValue).single": "left"], forKey: "T1ButtonActions")
T1Button.migrateControllerDefaults(in: prefs)
require(prefs.dictionary(forKey: "T1ButtonActions")?.count == 1, "Migration must not overwrite later custom settings")
require(T1ButtonAction.codexMode.definition.key == 20 && T1ButtonAction.newChat.definition.key == 45,
        "Invalid ChatGPT shortcut")
print("PASS 自定义设置迁移和主页快捷键")

@MainActor func renderPages(to directory: URL) throws {
    _ = NSApplication.shared
    if CommandLine.arguments.count > 2 {
        guard let icon = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        NSApplication.shared.applicationIconImage = icon
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let renderName = "local.codex.t1.render." + UUID().uuidString
    let renderPrefs = UserDefaults(suiteName: renderName)!
    defer { renderPrefs.removePersistentDomain(forName: renderName) }
    let profiles = T1ProfileStore(defaults: renderPrefs, observeApps: false)
    let model = T1DashboardModel()
    model.ready = true
    model.defaultInput = "T1 USB-Compatible Mic"
    model.status = "已连接，可开启麦克风"
    model.bluetooth = true
    model.accessibility = true
    model.inputMonitoring = true
    for page in T1DashboardPage.allCases {
        model.page = page
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let host = NSHostingView(rootView: T1Dashboard(
                model: model, audioDevice: model.defaultInput, version: "0.15.2", profiles: profiles,
                start: {}, stop: {}, authorize: {}, modeChanged: {}))
            let frame = CGRect(x: 0, y: 0, width: 855, height: 620)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = frame
            wait(0.08)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: frame) else {
                throw CocoaError(.fileWriteUnknown)
            }
            host.cacheDisplay(in: frame, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]), png.count > 35_000 else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: directory.appendingPathComponent("\(page.rawValue)-\(label).png"))
            window.close()
        }
    }
    print("PASS \(T1DashboardPage.allCases.count) 个页面的浅色和深色渲染")
}

if CommandLine.arguments.count > 1 {
    try MainActor.assumeIsolated {
        try renderPages(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    }
}
