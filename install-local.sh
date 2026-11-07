#!/bin/zsh
set -eu
umask 077

project=${0:A:h}
candidate=${T1_INSTALL_CANDIDATE:-"$project/Build/RemoteVox.app"}
target="$HOME/Applications/RemoteVox.app"
previous="$HOME/Applications/T1 Controller.app"
legacy="$HOME/Applications/T1 Microphone.app"
existing=()
for app in "$target" "$previous" "$legacy"; do
  if [[ -e "$app" || -L "$app" ]]; then existing+=("$app"); fi
done
logs="$HOME/Library/Logs/T1 Microphone"
identifier="local.codex.t1microphone"
certificate="$HOME/Library/Application Support/T1 Microphone/Signing/T1Controller.pem"
hash=$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | tr -d : | cut -d= -f2)
/usr/bin/codesign --verify --strict -R "=identifier \"$identifier\" and certificate leaf = H\"$hash\"" "$candidate"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist") == "$identifier" ]]
for app in "${existing[@]}"; do
  [[ ! -L "$app" && $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == "$identifier" ]]
done
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+(\.[0-9]+)+$' ]]

if [[ ${1:-} == --check ]]; then
  print -r -- "安装来源：$candidate"
  print -r -- "安装位置：$target"
  exit 0
fi

/usr/bin/swift -e '
import ApplicationServices
let state = CGSessionCopyCurrentDictionary() as? [String: Any]
if state == nil || state?["CGSSessionScreenIsLocked"] as? Bool == true {
    print("请解锁 Mac 后再安装 RemoteVox 更新。")
    exit(3)
}'

mkdir -p "${target:h}" "$logs"
backup=$(mktemp -d "$project/Build/Previous.XXXXXX")
stage=$(mktemp -d "${target:h}/.remotevox-install.XXXXXX")
installedNew=0
stopped=0
cleanup() {
  local result=$?
  if (( result != 0 && stopped )); then
    if (( installedNew )); then /bin/mv "$target" "$stage/failed.app"; fi
    for app in "${existing[@]}"; do
      if [[ -d "$backup/${app:t}" ]]; then /bin/mv "$backup/${app:t}" "$app"; fi
    done
    if (( ${#existing} )); then
      /usr/bin/open -g -j -a "${existing[1]}" --args --background || true
    fi
  fi
  /usr/bin/python3 - "$stage" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT

/usr/bin/ditto "$candidate" "$stage/RemoteVox.app"
/usr/bin/codesign --verify --strict "$stage/RemoteVox.app"
/usr/bin/osascript -l JavaScript -e '
function run(paths) {
    ObjC.import("AppKit");
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("local.codex.t1microphone");
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        if (paths.indexOf(ObjC.unwrap(app.bundleURL.path)) >= 0) app.terminate;
    }
}' "$target" "$previous" "$legacy"
pattern="^(${target//./\\.}|${previous//./\\.}|${legacy//./\\.})/Contents/MacOS/T1Microphone([[:space:]]|$)"
for i in {1..25}; do
  if ! /usr/bin/pgrep -qf "$pattern"; then break; fi
  /bin/sleep 0.2
done
if /usr/bin/pgrep -qf "$pattern"; then
  print -u2 'RemoteVox 的后台程序仍在运行，稍后再试。'
  exit 1
fi
stopped=1

for app in "${existing[@]}"; do /bin/mv "$app" "$backup/${app:t}"; done
/bin/mv "$stage/RemoteVox.app" "$target"
installedNew=1
/usr/bin/codesign --verify --strict "$target"
/usr/bin/open -a "$target" --stdout "$logs/controller-stable-$version.log" --stderr "$logs/controller-stable-$version.err"
print -r -- "已安装。上一版备份：$backup"
