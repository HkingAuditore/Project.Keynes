#!/bin/bash
# Build the two device frameworks used by the iOS Coast Pan release preset.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$repo/gdext"
scons platform=ios arch=arm64 target=template_release ios_min_version=17.0 "$@"
dest="$repo/Project/project-keynes/addons/dots_ext/bin/ios"
cpp="${GODOT_CPP_DIR:-godot-cpp}/bin"
stage="$(mktemp -d "$dest/.frameworks.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
for lib in dots_ext godot-cpp; do
    prefix="lib$lib.ios.template_release"
    source="$dest"
    if [[ "$lib" == godot-cpp ]]; then source="$cpp"; fi
    xcodebuild -create-xcframework -library "$source/$prefix.arm64.a" -output "$stage/$prefix.xcframework"
done
for framework in "$stage"/*.xcframework; do
    target="$dest/$(basename "$framework")"
    if [[ -d "$target" ]]; then mv "$target" "$stage/previous-$(basename "$framework")"; fi
    mv "$framework" "$target"
done
