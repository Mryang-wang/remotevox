import AppKit
import ApplicationServices
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

var testAppID: String? = "test.app"
var testIsT1 = true
let suite = "local.codex.t1.gestures." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
let profiles = T1ProfileStore(defaults: preferences, observeApps: false)
var outcomes: [String] = []
let controller = T1Controller(openMic: { false }, audioReady: { false }, closeMic: {},
    handlesVoiceKey: { false }, log: { outcomes.append($0) }, profiles: profiles)

func wait(_ time: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: time)) }
func home(_ down: Bool) { controller.onReport(2, down ? [2, 0x23, 2] : [2, 0, 0]) }
func back(_ down: Bool) { controller.onReport(2, down ? [2, 0x24, 2] : [2, 0, 0]) }
func menu(_ down: Bool) { controller.onReport(1, [1, 0, 0, down ? 0x65 : 0, 0, 0, 0, 0, 0]) }
func check(_ expected: [String]) {
    require(outcomes == expected, "Expected \(expected), got \(outcomes)")
    outcomes.removeAll()
}

home(true); home(false); wait(0.38)
check(["home.single.showDesktop"])
home(true); home(false); wait(0.05); home(true); home(false); wait(0.38)
check(["home.double.runningApps"])
home(true); wait(0.61); home(false); wait(0.38)
check(["home.hold.newChat"])
back(true); back(false); back(true); back(false)
check([])
menu(true); menu(false); wait(0.38)
check(["menu.single.appsMenu"])
menu(true); menu(false); wait(0.05); menu(true); menu(false); wait(0.38)
check(["menu.double.copy"])
menu(true); wait(0.61); menu(false); wait(0.38)
check(["menu.hold.paste"])
for usage: UInt8 in [0x4F, 0x50, 0x51, 0x52, 0x28] {
    controller.onReport(1, [1, 0, 0, usage, 0, 0, 0, 0, 0])
    controller.onReport(1, [1, 0, 0, 0, 0, 0, 0, 0, 0])
}
check([])
print("PASS 主页三种手势、复制粘贴、返回键无默认快捷键、方向键和 OK 由系统处理")

func mute(_ down: Bool) { controller.onReport(2, down ? [2, 0xE2, 0] : [2, 0, 0]) }
mute(true); mute(false); wait(0.38)
check(["mute.single.mute"])
profiles.setBinding(T1Binding(.copy), button: .mute, gesture: .double, profileID: nil)
profiles.setBinding(T1Binding(.paste), button: .mute, gesture: .hold, profileID: nil)
mute(true); mute(false); wait(0.05); mute(true); mute(false); wait(0.38)
check(["mute.double.copy"])
mute(true); wait(0.61); mute(false); wait(0.38)
check(["mute.hold.paste"])

home(true); home(false)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
wait(0.38)
check([])
home(true)
profiles.setBinding(T1Binding(.copy),button:.home,gesture:.hold,profileID:nil)
wait(0.65); home(false); wait(0.38)
check([])
profiles.recordingShortcut = true
menu(true); menu(false); wait(0.38)
check([])
profiles.recordingShortcut = false
print("PASS 静音三种手势、切换应用取消待执行动作、配置修改取消长按、录入快捷键时暂停控制")

let nativeURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Native App.app")
try FileManager.default.createDirectory(at: nativeURL.appendingPathComponent("Contents"),withIntermediateDirectories:true)
let info = try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"test.native","CFBundleName":"Native App"],format:.xml,options:0)
try info.write(to:nativeURL.appendingPathComponent("Contents/Info.plist"))
let nativeID = try profiles.addApp(nativeURL)
profiles.updateApp(nativeID,nativeMode:true)
testAppID = nativeID
home(true); home(false); menu(true); menu(false); mute(true); mute(false); wait(0.4)
check([])
testAppID = "test.app"
menu(true); menu(false); wait(0.38)
check(["menu.single.appsMenu"])
print("PASS 原生应用跳过自定义手势，切回其他应用恢复通用映射")

@discardableResult
func navigation(_ button: T1Button, _ down: Bool, flags: CGEventFlags = [], repeatKey: Bool = false) -> Bool {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: button.navigationKeyCode!, keyDown: down)!
    event.flags = flags
    if repeatKey { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    return controller.handleEvent(down ? .keyDown : .keyUp, event)
}
for button in [T1Button.up, .down, .left, .right, .ok] {
    require(!navigation(button, true) && !navigation(button, false), "Default navigation must pass through")
}
profiles.setBinding(T1Binding(.copy), button: .up, gesture: .single, profileID: nil)
profiles.setBinding(T1Binding(.paste), button: .up, gesture: .double, profileID: nil)
profiles.setBinding(T1Binding(.selectAll), button: .up, gesture: .hold, profileID: nil)
require(navigation(.up, true) && navigation(.up, false), "Configured navigation must consume both edges")
wait(0.40)
check(["up.single.copy"])
navigation(.up, true); navigation(.up, false); wait(0.05)
navigation(.up, true); navigation(.up, false); wait(0.40)
check(["up.double.paste"])
navigation(.up, true); navigation(.up, true, repeatKey: true); wait(0.66)
navigation(.up, false)
check(["up.hold.selectAll"])
profiles.setBinding(T1Binding(.copy), button: .ok, gesture: .hold, profileID: nil)
navigation(.ok, true); navigation(.ok, false)
check(["ok.single.native"])
require(!navigation(.up, true, flags: .maskCommand), "Modified key must pass through")
testIsT1 = false
require(!navigation(.up, true), "Another keyboard must pass through")
testIsT1 = true
testAppID = nativeID
require(!navigation(.up, true) && !navigation(.up, false), "Native app profile must pass through")
check([])
print("PASS 五个导航键原生直通、单击双击长按、修饰键和其他键盘隔离")
