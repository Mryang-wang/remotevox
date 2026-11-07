import AppKit
import SwiftUI

struct T1ShortcutRecorder: View {
    let recorded: (T1Shortcut) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("按下要录入的快捷键").font(.title2.weight(.semibold))
            Text("可以使用单个按键或组合键，例如空格、⌘C、⌥⌘F。按 Esc 取消。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ShortcutCapture(recorded: recorded, cancel: cancel).frame(height: 28)
            Button("取消", action: cancel)
        }
        .padding(28).frame(width: 400)
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    let recorded: (T1Shortcut) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.recorded = recorded
        view.cancel = cancel
        return view
    }

    func updateNSView(_ view: ShortcutCaptureView, context: Context) {}
}

private final class ShortcutCaptureView: NSView {
    var recorded: ((T1Shortcut) -> Void)?
    var cancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) { capture(event) }

    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        if event.keyCode == 53 && flags.isEmpty { cancel?(); return }
        var label = ""
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }
        if flags.contains(.function) { label += "Fn " }
        let special: [UInt16: String] = [36:"Return",48:"Tab",49:"空格",51:"⌫",76:"Enter",117:"⌦",
                                       123:"←",124:"→",125:"↓",126:"↑",53:"Esc",115:"Home",119:"End",116:"Page Up",121:"Page Down",
                                       122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",
                                       109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        label += special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        let shortcut = T1Shortcut(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), label: label)
        guard shortcut.valid else { return }
        recorded?(shortcut)
    }
}
