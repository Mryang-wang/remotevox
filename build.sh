#!/bin/zsh
set -eu
umask 077

project=${0:A:h}
output=${1:-"$project/Build/RemoteVox.app"}
build_number=${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project/Info.plist")}
version=${3:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project/Info.plist")}
signing="$HOME/Library/Application Support/T1 Microphone/Signing"
keychain="$signing/T1Controller.keychain-db"
password_file="$signing/keychain-password"
certificate="$signing/T1Controller.pem"
identifier="local.codex.t1microphone"
scratch=$(mktemp -d /tmp/t1-build.XXXXXX)
cleanup() {
  /usr/bin/security lock-keychain "$keychain" >/dev/null 2>&1 || true
  /usr/bin/python3 - "$scratch" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT

mkdir -p "$signing" "${output:h}"
if [[ ! -f "$keychain" ]]; then
  password=$(/usr/bin/openssl rand -hex 32)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj '/CN=RemoteVox Local Signing/' \
    -keyout "$scratch/signing.key" -out "$scratch/certificate.pem" \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=codeSigning' \
    -addext 'basicConstraints=critical,CA:FALSE' 2>"$scratch/openssl.log"
  /usr/bin/openssl pkcs12 -export -inkey "$scratch/signing.key" \
    -in "$scratch/certificate.pem" -out "$scratch/signing.p12" \
    -passout "pass:$password" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
  /usr/bin/security create-keychain -p "$password" "$keychain"
  /usr/bin/security unlock-keychain -p "$password" "$keychain"
  /usr/bin/security import "$scratch/signing.p12" -f pkcs12 -k "$keychain" \
    -P "$password" -T /usr/bin/codesign >/dev/null
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$password" "$keychain" >/dev/null
  /bin/cp "$scratch/certificate.pem" "$certificate"
  printf '%s\n' "$password" > "$password_file"
fi
if [[ ! -s "$certificate" || ! -s "$password_file" ]]; then
  print -u2 'T1 签名文件不完整。请先恢复原签名文件，以保留更新身份。'
  exit 2
fi

password=$(<"$password_file")
/usr/bin/security unlock-keychain -p "$password" "$keychain"
unset password
hash=$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | tr -d : | cut -d= -f2)
printf 'designated => identifier "%s" and certificate leaf = H"%s"\n' "$identifier" "$hash" > "$scratch/designated.req"

app="$scratch/RemoteVox.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
/bin/mkdir -p "$contents/Library/LaunchAgents"
/usr/bin/install -m 755 "$project/Packaging/t1-login.sh" "$contents/Resources/t1-login.sh"
/bin/cp "$project/Packaging/local.codex.t1microphone.background.plist" "$contents/Library/LaunchAgents/"
/bin/cp "$project/Info.plist" "$contents/Info.plist"
/bin/cp "$project/LICENSE" "$contents/Resources/LICENSE"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" \
  -c "Set :CFBundleShortVersionString $version" "$contents/Info.plist"
icon_source="$project/Assets/T1AppIcon.png"
iconset="$scratch/T1AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  retina=$((size * 2))
  /usr/bin/sips -z "$size" "$size" "$icon_source" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z "$retina" "$retina" "$icon_source" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$contents/Resources/T1AppIcon.icns"
/bin/cp "$iconset/icon_256x256.png" "$contents/Resources/T1DashboardIcon.png"
/bin/cp "$project/Sources/Bridge.swift" "$scratch/main.swift"
/bin/cp "$project"/Sources/*.swift "$contents/Resources/"
/usr/bin/xcrun swiftc -O -target arm64-apple-macos27.0 "$scratch/main.swift" "$project/Sources/Controller.swift" \
  "$project/Sources/ButtonSettings.swift" "$project/Sources/Dashboard.swift" \
  "$project/Sources/SystemNavigation.swift" "$project/Sources/Profiles.swift"   "$project/Sources/AppProfilesView.swift" "$project/Sources/ShortcutRecorder.swift"   "$project/Sources/InputEvents.swift" "$project/Sources/LocalDictation.swift" -o "$contents/MacOS/T1Microphone"
/usr/bin/codesign --force --sign "$hash" --keychain "$keychain" --timestamp=none \
  --requirements "$scratch/designated.req" "$app"
/usr/bin/codesign --verify --strict "$app"
if [[ -e "$output" ]]; then
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist") == "$identifier" ]]
  /bin/mv "$output" "$scratch/previous.app"
fi
if ! /usr/bin/ditto "$app" "$output" || ! /usr/bin/codesign --verify --strict "$output"; then
  if [[ -e "$output" ]]; then /bin/mv "$output" "$scratch/failed.app"; fi
  if [[ -d "$scratch/previous.app" ]]; then /bin/mv "$scratch/previous.app" "$output"; fi
  exit 3
fi
print -r -- "$output"
