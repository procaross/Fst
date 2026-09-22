#!/bin/zsh
# Install the signed Release product without retaining stale Debug dylibs or providers.
set -eu
cd "${0:A:h:h}"
product="$PWD/build/dd/Build/Products/Release/Fst.app"
extension_path="Contents/PlugIns/FstQuickLook.appex"
target_app="/Applications/Fst.app"
identifier="com.procaross.Fst.QuickLook"
codesign --verify --deep --strict "$product"
codesign -d --entitlements :- "$product/$extension_path" 2>/dev/null | python3 -c 'import plistlib,sys; assert plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.app-sandbox") is True'
backup="$PWD/build/install-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
if [[ -d "$target_app" ]]; then
    pluginkit -r "$target_app/$extension_path" || true
    mv "$target_app" "$backup/Fst.backup"
fi
if ! ditto "$product" "$target_app"; then
    [[ ! -d "$target_app" ]] || mv "$target_app" "$backup/Incomplete.backup"
    [[ ! -d "$backup/Fst.backup" ]] || mv "$backup/Fst.backup" "$target_app"
    exit 1
fi
codesign --verify --deep --strict "$target_app"
for configuration in Debug Release; do
    candidate="$PWD/build/dd/Build/Products/$configuration/Fst.app/$extension_path"
    [[ ! -d "$candidate" ]] || pluginkit -r "$candidate" || true
done
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
pluginkit -a "$target_app/$extension_path"
pluginkit -e use -i "$identifier"
# Only terminate this app's read-only preview process, never an editor with unsaved documents.
for pid in ${(f)"$(pgrep -f '^/Applications/Fst.app/Contents/PlugIns/FstQuickLook.appex/Contents/MacOS/FstQuickLook' || true)"}; do
    [[ -z "$pid" ]] || kill "$pid" || true
done
qlmanage -r
pluginkit -m -A -D -v -i "$identifier"
