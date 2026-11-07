#!/bin/zsh
set -eu
umask 077
export COPYFILE_DISABLE=1

project=${0:A:h}
scratch=$(mktemp -d /tmp/t1-package.XXXXXX)
trap '/bin/rm -rf -- "$scratch"' EXIT
app_root="$scratch/app"
driver_root="$scratch/audio"
app="$app_root/RemoteVox.app"
driver="$driver_root/T1SiriInput.driver"
mkdir -p "$app_root" "$driver/Contents/MacOS" "$driver/Contents/Resources" "$scratch/resources"

"$project/build.sh" "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" > "$scratch/version"
version=$(<"$scratch/version")
output=${1:-"$project/Build/RemoteVox-$version-arm64.pkg"}

/bin/cp "$project/Driver/Info.plist" "$driver/Contents/Info.plist"
/bin/cp "$project/Driver/LICENSE" "$driver/Contents/Resources/LICENSE"
xcrun clang -arch arm64 -O2 -bundle -mmacosx-version-min=14.0 \
    '-DkDriver_Name="T1SiriInput"' '-DkDevice_Name="T1 USB-Compatible Mic"' \
    '-DkPlugIn_BundleID="local.codex.audio.T1SiriInput"' -DkNumber_Of_Channels=2 \
    "$project/Driver/BlackHole-T1.c" -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    -o "$driver/Contents/MacOS/T1SiriInput"
codesign --force --sign - "$driver"
chmod -R a+rX,go-w "$app_root" "$driver_root"
/usr/bin/xattr -cr "$app_root" "$driver_root"
codesign --verify --strict "$driver"
codesign --verify --strict "$app"

make_component() {
    local root=$1 location=$2 identifier=$3 component_version=$4 output_name=$5
    shift 5
    local definition="$scratch/$output_name.plist"
    pkgbuild --analyze --root "$root" "$definition"
    /usr/bin/plutil -replace 0.BundleIsRelocatable -bool NO "$definition"
    pkgbuild --root "$root" --component-plist "$definition" --ownership recommended \
        --identifier "$identifier" --version "$component_version" --install-location "$location" "$@" \
        "$scratch/$output_name.pkg"
}

driver_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$driver/Contents/Info.plist")
make_component "$app_root" /Applications local.codex.t1microphone.pkg "$version" RemoteVox \
    --scripts "$project/Packaging/AppScripts"
make_component "$driver_root" /Library/Audio/Plug-Ins/HAL local.codex.audio.T1SiriInput.pkg "$driver_version" T1Audio
/bin/cp "$project/Packaging/Welcome.html" "$scratch/resources/"
mkdir -p "${output:h}"
productbuild --distribution "$project/Packaging/Distribution.xml" --package-path "$scratch" \
    --resources "$scratch/resources" "$scratch/RemoteVox-Installer.pkg"
pkgutil --payload-files "$scratch/RemoteVox-Installer.pkg" >/dev/null
/usr/bin/install -m 644 "$scratch/RemoteVox-Installer.pkg" "$output"
(cd "${output:h}" && /usr/bin/shasum -a 256 "${output:t}" > "${output:t}.sha256")
print -r -- "$output"
