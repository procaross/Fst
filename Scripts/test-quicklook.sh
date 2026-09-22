#!/bin/zsh
set -eu
cd "${0:A:h:h}"
products="$PWD/build/dd/Build/Products/Release"
modulemap="$PWD/Vendor/CMarkGFM/Sources/libcmark/module.modulemap"
[[ -f "$products/SwiftMath.o" ]] || { print -u2 'Build Release first.'; exit 1; }
mkdir -p build/quicklook-tests
swiftc -O -I "$products" -I Vendor/CMarkGFM/Sources/libcmark \
  -Xcc "-fmodule-map-file=$modulemap" \
  FstQuickLook/*.swift Fst/EditorTheme.swift Fst/EditorPreferences.swift \
  Fst/CustomThemes.swift Fst/SyntaxLexer.swift Fst/Performance.swift \
  Tests/QuickLook/main.swift "$products/libcmark.o" "$products/SwiftMath.o" \
  -o build/quicklook-tests/tests
ditto "$products/SwiftMath_SwiftMath.bundle" build/quicklook-tests/SwiftMath_SwiftMath.bundle
build/quicklook-tests/tests "$@"
