import AppKit
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError(description) }
}
let suite = "local.codex.t1.profilechecks." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName:suite) }
prefs.set(true, forKey:"T1ControllerPresetApplied")
prefs.set(true, forKey:"T1AppPickerPresetApplied")
prefs.set(["458853.hold":"paste","786980.single":"none"],forKey:"T1ButtonActions")
let store = T1ProfileStore(defaults:prefs,observeApps:false)
require(store.binding(.back,.single,in:nil).action == .none, "Legacy back must remain unchanged")
require(store.binding(.menu,.hold,in:nil).action == .paste, "Legacy paste must survive")
require(store.binding(.home,.double,in:nil).action == .runningApps,"Switcher default")
require(store.binding(.mute,.single,in:nil).action == .mute,"Mute default")
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
func fixture(_ id:String,_ name:String) throws -> URL {
    let app = root.appendingPathComponent(name + ".app",isDirectory:true)
    let contents = app.appendingPathComponent("Contents",isDirectory:true)
    try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
    let plist = ["CFBundleIdentifier":id,"CFBundleName":name,"CFBundlePackageType":"APPL"]
    let data = try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0)
    try data.write(to:contents.appendingPathComponent("Info.plist"))
    return app
}
let a = try store.addApp(fixture("test.profile.a","Player A"))
let b = try store.addApp(fixture("test.profile.b","Player B"))
_ = try store.addApp(fixture("test.profile.a","Player A"))
require(store.apps.count == 2,"Deduplicate apps")
require(store.binding(.home,.single,in:a).action == .inherit,"New app inherits")
require(store.effective(.home,.single,appID:a).action == .showDesktop,"Inherited behavior")
let shortcut = T1Shortcut(keyCode:49,modifiers:0,label:"空格")
require(shortcut.valid,"Bare media shortcut")
store.setBinding(T1Binding(.customShortcut,shortcut:shortcut),button:.menu,gesture:.single,profileID:a)
require(store.effective(.menu,.single,appID:a).shortcut == shortcut,"App custom shortcut")
require(store.effective(.menu,.single,appID:b).action == .appsMenu,"App isolation")
store.setBinding(T1Binding(.copy),button:.menu,gesture:.single,profileID:nil)
require(store.effective(.menu,.single,appID:a).shortcut == shortcut,"Override beats global")
require(store.effective(.menu,.single,appID:b).action == .copy,"Inheritance follows global")
store.setBinding(T1Binding(.none),button:.menu,gesture:.single,profileID:b)
require(store.effective(.menu,.single,appID:b).action == .none,"No action differs from inheritance")
store.updateApp(a,nativeMode:true)
for button in T1Button.allCases {
    for gesture in T1Gesture.allCases {
        require(store.effective(button,gesture,appID:a).action == .native,"Native mode for all configured gestures")
    }
}
store.updateApp(a,enabled:false)
require(!store.isNative(a),"Disabled native profile")
require(store.effective(.menu,.single,appID:a).action == .copy,"Disabled profile uses general")
store.updateApp(a,enabled:true,nativeMode:false)
let restored = T1ProfileStore(defaults:prefs,observeApps:false)
require(restored.effective(.menu,.single,appID:a).shortcut == shortcut,"Shortcut persistence")
require(restored.apps.count == 2,"App persistence")
store.reset(a)
require(store.effective(.menu,.single,appID:a).action == .copy,"Reset to inheritance")
store.removeApp(b)
require(store.apps.count == 1 && store.binding(.menu,.single,in:nil).action == .copy,"Remove app preserves global")
let bad = Data("invalid config".utf8)
prefs.set(bad,forKey:T1ProfileStore.storageKey)
let corrupted = T1ProfileStore(defaults:prefs,observeApps:false)
corrupted.reset(nil)
require(corrupted.error != nil && prefs.data(forKey:T1ProfileStore.storageKey) == bad,"Keep invalid data intact")
let unrelated: [UInt64:UInt64] = [12:34,0x700000065:0x70000006A]
let mapped = T1DeviceMapping.apply(to:unrelated,native:false)
let native = T1DeviceMapping.apply(to:mapped,native:true)
require(native[12] == 34,"Preserve unrelated mappings")
require(native[0x100000081] == 0x70000006E,"Keep power handling")
require(native[0xC000000E2] == nil && native[0xC00000221] == nil && native[0x700000065] == nil,"Restore real native HID")
require(T1DeviceMapping.apply(to:native,native:false) == mapped,"Restore custom mapping after native app")
require(!T1Shortcut(keyCode:128,modifiers:0,label:"bad").valid,"Reject invalid shortcut")
print("PASS 旧设置迁移、添加应用、继承、独立快捷键、原生模式、禁用、保存重载、恢复、删除和设备映射往返")
