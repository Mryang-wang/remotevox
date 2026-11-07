#!/bin/zsh
set -eu

project=${0:A:h}
scratch=$(mktemp -d /tmp/t1-test.XXXXXX)
cleanup() {
  /usr/bin/python3 - "$scratch" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT
src="$project/Sources"
out="$project/Build/Tests"
mkdir -p "$out"

/bin/cp "$project/Tests/ControllerChecks.swift" "$scratch/main.swift"
xcrun swiftc -O "$scratch/main.swift" "$src/ButtonSettings.swift" \
  "$src/Dashboard.swift" "$src/Profiles.swift" "$src/AppProfilesView.swift" \
  "$src/ShortcutRecorder.swift" "$src/LocalDictation.swift" -o "$scratch/controller-checks"
"$scratch/controller-checks" "$out/previews" "$project/Assets/T1AppIcon.png"

# Exercise the real report and gesture decoder without delivering key events.
/usr/bin/python3 - "$src/Controller.swift" "$scratch/TestController.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
source = source.replace('private func onReport(', 'func onReport(')
source = source.replace('private func handleEvent(', 'func handleEvent(')
source = source.replace('T1DeviceEvent.isT1(event)', 'testIsT1')
source = source.replace('AXIsProcessTrusted(), !profiles.recordingShortcut', '!profiles.recordingShortcut')
source = source.replace('guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }', 'let pid: pid_t = 123')
source = source.replace('NSWorkspace.shared.frontmostApplication?.bundleIdentifier', 'testAppID')
start = source.index('    private func perform(')
end = source.index('    private func openChatGPT(', start)
source = source[:start] + r'''
    private func perform(_ binding: T1Binding, button: T1Button, gesture: T1Gesture, pid: pid_t) {
        let action = binding.action
        guard action != .none && action != .inherit else { return }
        log("\(button).\(gesture.rawValue).\(action.rawValue)")
    }

''' + source[end:]
start = source.index('    private func foregroundPID()')
end = source.index('    private func post(', start)
source = source[:start] + '    private func foregroundPID() -> pid_t? { nil }\n\n' + source[end:]
Path(sys.argv[2]).write_text(source)
PY
/bin/cp "$project/Tests/GestureChecks.swift" "$scratch/main.swift"
xcrun swiftc -O "$scratch/main.swift" "$scratch/TestController.swift" \
  "$src/ButtonSettings.swift" "$src/SystemNavigation.swift" "$src/Profiles.swift" \
  "$src/InputEvents.swift" -o "$scratch/gesture-checks"
"$scratch/gesture-checks" "$scratch"

/bin/cp "$project/Tests/ProfileChecks.swift" "$scratch/main.swift"
xcrun swiftc -O "$scratch/main.swift" "$src/ButtonSettings.swift" "$src/Profiles.swift" \
  "$src/InputEvents.swift" -o "$scratch/profile-checks"
"$scratch/profile-checks" "$scratch"

/bin/cp "$project/Tests/ShortcutRecorderChecks.swift" "$scratch/main.swift"
xcrun swiftc -O "$scratch/main.swift" "$src/ShortcutRecorder.swift" "$src/Profiles.swift" \
  "$src/ButtonSettings.swift" -o "$scratch/shortcut-checks"
"$scratch/shortcut-checks"
