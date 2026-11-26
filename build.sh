#!/bin/sh
# Builds HostManager.app.
#
#   ./build.sh              release build into dist/HostManager.app
#   ./build.sh --debug      debug build (faster to compile, slower to run)
#   ./build.sh --install    also copy the result into /Applications
#
# Needs only Xcode's Command Line Tools: swift, codesign.
set -eu

cd "$(dirname "$0")"

configuration=release
install=false
for argument in "$@"; do
    case "$argument" in
        --debug) configuration=debug ;;
        --install) install=true ;;
        *) echo "unknown option: $argument" >&2; exit 64 ;;
    esac
done

app="dist/HostManager.app"
contents="$app/Contents"

echo "Compiling ($configuration)…"
swift build -c "$configuration" --product HostManager

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

cp ".build/$configuration/HostManager" "$contents/MacOS/HostManager"
cp Resources/Info.plist "$contents/Info.plist"
printf 'APPL????' > "$contents/PkgInfo"
if [ -f Resources/HostManager.icns ]; then
    cp Resources/HostManager.icns "$contents/Resources/HostManager.icns"
fi
for language in zh-Hans en; do
    mkdir -p "$contents/Resources/$language.lproj"
    cp "Resources/$language.lproj/Localizable.strings" "$contents/Resources/$language.lproj/"
done

# Ad-hoc signature: enough to run locally, and required on Apple Silicon.
codesign --force --sign - --timestamp=none "$app" >/dev/null

echo "Built $app"
if $install; then
    rm -rf /Applications/HostManager.app
    ditto "$app" /Applications/HostManager.app
    echo "Installed /Applications/HostManager.app"
fi
