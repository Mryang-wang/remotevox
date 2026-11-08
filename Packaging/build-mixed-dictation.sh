#!/bin/zsh
set -eu

project=${0:A:h:h}
contents=$1
scratch=$2
keychain=$3
identity=$4
version=2.0.1
archive="sherpa-onnx-v$version-osx-arm64-shared-no-tts-lib"
cache="$project/Build/Dependencies/sherpa-onnx-$version"
sherpa_source="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$version"
ort_source="https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2"
mkdir -p "$cache" "$contents/Frameworks" "$contents/Helpers" "$contents/Resources/Licenses"

fetch() {
    local name=$1 url=$2 digest=$3
    if [[ -f "$cache/$name" ]] && printf '%s  %s\n' "$digest" "$cache/$name" | shasum -a 256 -c --status; then
        return
    fi
    /usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 \
        --max-time 180 --output "$scratch/$name" "$url"
    printf '%s  %s\n' "$digest" "$scratch/$name" | shasum -a 256 -c
    /bin/mv -f "$scratch/$name" "$cache/$name"
}

fetch "$archive.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$version/$archive.tar.bz2" \
    ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3
fetch c-api.h "$sherpa_source/sherpa-onnx/c-api/c-api.h" \
    5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
fetch sherpa-onnx-LICENSE.txt "$sherpa_source/LICENSE" \
    cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
fetch onnxruntime-LICENSE.txt "$ort_source/LICENSE" \
    2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
fetch onnxruntime-ThirdPartyNotices.txt "$ort_source/ThirdPartyNotices.txt" \
    0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2

/usr/bin/tar -xjf "$cache/$archive.tar.bz2" -C "$scratch"
for library in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
    /usr/bin/install -m 755 "$scratch/$archive/lib/$library" "$contents/Frameworks/$library"
    /usr/bin/codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$contents/Frameworks/$library"
done
/bin/cp "$cache/"*.txt "$contents/Resources/Licenses/"
xcrun clang -O2 -arch arm64 -mmacosx-version-min=27.0 -I"$cache" \
    "$project/Packaging/mixed-dictation.c" -L"$contents/Frameworks" -lsherpa-onnx-c-api \
    -Wl,-rpath,@loader_path/../Frameworks -o "$contents/Helpers/RemoteVoxMixed"
/usr/bin/codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$contents/Helpers/RemoteVoxMixed"
