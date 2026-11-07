import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var saved: [T1Shortcut] = []
var cancelled = 0
let host = NSHostingView(rootView:T1ShortcutRecorder(recorded:{saved.append($0)},cancel:{cancelled += 1}))
let window = NSWindow(contentRect:NSRect(x:0,y:0,width:450,height:240),styleMask:[.titled],backing:.buffered,defer:false)
window.isReleasedWhenClosed = false
window.contentView = host
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2))
guard let responder = window.firstResponder else { fatalError("No capture responder") }
func key(_ code:UInt16,_ text:String,_ flags:NSEvent.ModifierFlags = []) {
    let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,
        windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,
        isARepeat:false,keyCode:code)!
    if flags.contains(.command) { _ = responder.performKeyEquivalent(with:event) }
    else { responder.keyDown(with:event) }
}
key(8,"c",.command)
key(49," ")
key(97,"\u{F709}")
key(53,"\u{1b}")
guard saved.count == 3, saved[0].keyCode == 8, saved[0].modifiers == CGEventFlags.maskCommand.rawValue,
    saved[0].label == "⌘C", saved[1].label == "空格", saved[2].label == "F6", cancelled == 1 else {
    fatalError("Shortcut capture regression: \(saved) cancel \(cancelled)")
}
print("PASS 快捷键录入实际控件接收 ⌘C、空格、F6，Esc 取消")
window.close()
