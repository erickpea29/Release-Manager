#!/bin/zsh
# M00 visual check: opens the spike app once per window-material/appearance combination.
# Each window stays open until you quit it (⌘Q); then the next one opens.
#
# Usage: DEVELOPMENT_TEAM=<your team ID> spikes/M00/visual-check.sh
set -euo pipefail

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Development team ID}"
here=${0:A:h}
derived="$here/M00SpikeApp/build"
app="$derived/Build/Products/Debug/M00Spike.app"

echo "Building the spike app (team-signed)…"
# Always the same bundle ID and identity: changing the signer for a sandboxed bundle ID blocks launch (M00 F5).
xcodebuild -quiet -project "$here/M00SpikeApp/M00Spike.xcodeproj" -scheme M00Spike -configuration Debug \
  -derivedDataPath "$derived" -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER=com.erickpea29.ReleaseManager.M00Spike.teamsigned build

combinations=(
  "opaque light"
  "opaque dark"
  "swiftUIMaterial light"
  "swiftUIMaterial dark"
  "appKitVisualEffect light"
  "appKitVisualEffect dark"
)
step=1
for combination in $combinations; do
  material=${combination% *}
  appearance=${combination#* }
  echo
  echo "[$step/${#combinations}] Window material: $material · Appearance: $appearance"
  echo "    Look at the window, take a screenshot (⌘⇧4, Space, click the window), then quit it with ⌘Q."
  open -W -n "$app" --args -windowMaterial "$material" -appearance "$appearance"
  step=$((step + 1))
done
echo
echo "Done. Screenshots are on your Desktop."
