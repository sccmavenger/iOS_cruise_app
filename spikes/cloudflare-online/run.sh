#!/bin/zsh
# Rebuilds and reruns the Cloudflare online-games spike from the app's current rules.
#   spikes/cloudflare-online/run.sh            # everything, against the local Cloudflare runtime
# Needs: Xcode (for the macOS SDK), Node 20+, network access for the first run.
# Downloads the swift.org 6.4.1 toolchain and Wasm SDK into $WORK (not installed system-wide).
set -euo pipefail
HERE=${0:A:h}; REPO=${HERE:h:h}; WORK=${WORK:-/tmp/cf-spike}; G=$REPO/iso_cruise_app/Games
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH=$WORK/cache/clang SWIFTPM_MODULECACHE_OVERRIDE=$WORK/cache/spm
mkdir -p $WORK/dl
B=https://download.swift.org/swift-6.4.1-release
SDK_SHA=783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8  # published on swift.org
TC=$WORK/tc-expanded/swift-6.4.1-RELEASE-osx-package.pkg/Payload
if [ ! -x $TC/usr/bin/swift ]; then
  curl -sSL -o $WORK/dl/toolchain.pkg $B/xcode/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-osx.pkg
  pkgutil --check-signature $WORK/dl/toolchain.pkg | grep -q "Swift Open Source" || { echo "toolchain signature check failed"; exit 1; }
  rm -rf $WORK/tc-expanded; pkgutil --expand-full $WORK/dl/toolchain.pkg $WORK/tc-expanded
fi
if ! $TC/usr/bin/swift sdk list --swift-sdks-path $WORK/sdks 2>/dev/null | grep -q swift-6.4.1-RELEASE_wasm; then
  curl -sSL -o $WORK/dl/wasm.tar.gz $B/wasm-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_wasm.artifactbundle.tar.gz
  [ "$(shasum -a 256 $WORK/dl/wasm.tar.gz | cut -d' ' -f1)" = "$SDK_SHA" ] || { echo "Wasm SDK checksum mismatch"; exit 1; }
  mkdir -p $WORK/sdks; $TC/usr/bin/swift sdk install $WORK/dl/wasm.tar.gz --swift-sdks-path $WORK/sdks
fi

echo "== Copy the app's rules and apply the Phase 0 changes (copies only)"
R=$HERE/swift/Sources/CruiseGameRules
cp $G/GameProtocol.swift $G/GameEngine.swift $G/Cards/PlayingCard.swift $G/TicTacToe/TicTacToeRules.swift \
   $G/ConnectFour/ConnectFourRules.swift $G/Checkers/CheckersRules.swift $G/Chess/ChessRules.swift \
   $G/ColorMatch/ColorMatchModel.swift $G/ColorMatch/ColorMatchRules.swift $G/Spades/SpadesModel.swift \
   $G/Spades/SpadesRules.swift $G/Tonk/TonkModel.swift $G/Tonk/TonkRules.swift $R/
awk '/^nonisolated enum GameType/,/^}/' $REPO/iso_cruise_app/Networking/Envelope.swift > $R/GameType.swift
sed -i '' '/^import Foundation$/d' $R/*Rules.swift $R/*Model.swift $R/GameEngine.swift $R/GameProtocol.swift $R/PlayingCard.swift
sed -i '' 's/rawValue\.capitalized/rawValue.spikeCapitalized/g' $R/ColorMatchModel.swift $R/ChessRules.swift
sed -i '' 's/\.shuffled(using: &rng)/.portableShuffled(using: \&rng)/g; s/\.shuffle(using: &rng)/.portableShuffle(using: \&rng)/g' $R/ColorMatchRules.swift $R/TonkRules.swift $R/SpadesRules.swift
printf '\nextension ColorMatchState: Codable {}\nextension ColorMatchState.PendingDrawFour: Codable {}\n' >> $R/ColorMatchModel.swift
printf '\nextension SpadesState: Codable {}\n' >> $R/SpadesModel.swift
printf '\nextension TonkState: Codable {}\n' >> $R/TonkModel.swift
printf '\nextension GameEngine.State: Codable {}\n' >> $R/GameEngine.swift

echo "== Build native reference generator and the WebAssembly rules"
cd $HERE/swift
$TC/usr/bin/swift build -c release --product golden --scratch-path $WORK/build-native 2>&1 | grep -E "error|Build complete"
$TC/usr/bin/swift build -c release --product RulesWasm --swift-sdk swift-6.4.1-RELEASE_wasm --swift-sdks-path $WORK/sdks \
  --scratch-path $WORK/build-wasm-small -Xswiftc -Osize -Xswiftc -gnone -Xlinker --strip-all 2>&1 | grep -E "error|Build complete"
WASM=$WORK/build-wasm-small/out/Products/Release-webassembly-wasm32/RulesWasm.wasm
cp $WASM $HERE/worker/src/rules.wasm
printf 'Wasm size: %s bytes raw, %s bytes gzip -9\n' "$(stat -f %z $WASM)" "$(gzip -9 -c $WASM | wc -c | tr -d ' ')"

echo "== Native vs WebAssembly parity"
$WORK/build-native/release/golden 3 400 > $WORK/golden.jsonl
cd $HERE/worker; [ -d node_modules ] || npm install --silent --no-fund --no-audit
node parity-node.mjs $WORK/golden.jsonl

echo "== Durable Object scenarios on the local Cloudflare runtime (workerd)"
STATE=$WORK/state-run; rm -rf $STATE
start() { WRANGLER_SEND_METRICS=false CI=1 nohup node node_modules/wrangler/bin/wrangler.js dev --port 8787 --persist-to $STATE >> $WORK/wrangler.log 2>&1 &
          for i in {1..40}; do sleep 1; [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' localhost:8787/)" = "404" ] && return 0; done; return 1; }
stop() { pkill -9 -f "wrangler.js dev --port 8787" || true; pkill -9 -f "wrangler-dist/cli.js dev --port 8787" || true; pkill -9 -f "workerd serve" || true; sleep 1; }
stop; start
node scenarios.mjs all
node scenarios.mjs restart1
stop; echo "(runtime killed with kill -9)"; start
node scenarios.mjs restart2
node load.mjs 100
stop
