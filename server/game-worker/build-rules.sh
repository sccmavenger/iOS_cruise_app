#!/bin/zsh
# Builds src/rules.wasm from the app's game rules and checks it against native Swift.
#   server/game-worker/build-rules.sh            # build + parity check
#   server/game-worker/build-rules.sh --no-check # build only
# Needs Xcode (macOS SDK) and Node. The first run downloads the swift.org 6.4.1 toolchain and
# its WebAssembly SDK (about 1.7 GB) into ~/Library/Caches/CruiseLAN-swift-wasm. Xcode's own
# toolchain can't target WebAssembly.
set -euo pipefail
HERE=${0:A:h}; REPO=${HERE:h:h}; G=$REPO/iso_cruise_app/Games
CACHE=${CRUISELAN_WASM_CACHE:-$HOME/Library/Caches/CruiseLAN-swift-wasm}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH=$CACHE/module-cache/clang SWIFTPM_MODULECACHE_OVERRIDE=$CACHE/module-cache/spm
B=https://download.swift.org/swift-6.4.1-release
SDK_SHA=783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8  # published on swift.org
TC=$CACHE/tc-expanded/swift-6.4.1-RELEASE-osx-package.pkg/Payload
mkdir -p $CACHE/dl
if [ ! -x $TC/usr/bin/swift ]; then
  echo "Downloading the swift.org 6.4.1 toolchain…"
  curl -sSL -o $CACHE/dl/toolchain.pkg $B/xcode/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-osx.pkg
  pkgutil --check-signature $CACHE/dl/toolchain.pkg | grep -q "Developer ID Installer: Swift Open Source" || { echo "toolchain signature check failed"; exit 1; }
  rm -rf $CACHE/tc-expanded; pkgutil --expand-full $CACHE/dl/toolchain.pkg $CACHE/tc-expanded; rm $CACHE/dl/toolchain.pkg
fi
if ! $TC/usr/bin/swift sdk list --swift-sdks-path $CACHE/sdks 2>/dev/null | grep -qx swift-6.4.1-RELEASE_wasm; then
  echo "Downloading the Swift WebAssembly SDK…"
  curl -sSL -o $CACHE/dl/wasm.tar.gz $B/wasm-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_wasm.artifactbundle.tar.gz
  [ "$(shasum -a 256 $CACHE/dl/wasm.tar.gz | cut -d' ' -f1)" = "$SDK_SHA" ] || { echo "Wasm SDK checksum mismatch"; exit 1; }
  mkdir -p $CACHE/sdks; $TC/usr/bin/swift sdk install $CACHE/dl/wasm.tar.gz --swift-sdks-path $CACHE/sdks; rm $CACHE/dl/wasm.tar.gz
fi

# One source of truth: copy the app's rules in (gitignored) and refuse anything platform-specific.
R=$HERE/swift/Sources/CruiseGameRules
find $R -name '*.swift' ! -name Bridge.swift ! -name GoldenTrace.swift -delete
cp $G/GameType.swift $G/PortableSupport.swift $G/GameEngine.swift $G/GameProtocol.swift $G/Cards/PlayingCard.swift \
   $G/*/*Rules.swift $G/*/*Model.swift $R/
if grep -l '^import' $R/*.swift | grep -v -e Bridge.swift -e GoldenTrace.swift; then
  echo "The files above import a module. Game rules must use only the Swift standard library."; exit 1
fi

cd $HERE/swift
$TC/usr/bin/swift build -c release --product RulesWasm --swift-sdk swift-6.4.1-RELEASE_wasm --swift-sdks-path $CACHE/sdks \
  --scratch-path $CACHE/build-wasm -Xswiftc -Osize -Xswiftc -gnone -Xlinker --strip-all 2>&1 | grep -E "error|warning: |Build complete" || true
WASM=$CACHE/build-wasm/out/Products/Release-webassembly-wasm32/RulesWasm.wasm
[ -f $WASM ] || { echo "WebAssembly build failed"; exit 1; }
cp $WASM $HERE/src/rules.wasm
printf 'rules.wasm: %s bytes (%s gzip)\n' "$(stat -f %z $WASM)" "$(gzip -9 -c $WASM | wc -c | tr -d ' ')"

[ "${1:-}" = "--no-check" ] && exit 0
$TC/usr/bin/swift build -c release --product golden --scratch-path $CACHE/build-native 2>&1 | grep -E "error|Build complete" || true
$CACHE/build-native/release/golden 3 400 > $CACHE/golden.jsonl
cd $HERE && node test/parity.mjs $CACHE/golden.jsonl
