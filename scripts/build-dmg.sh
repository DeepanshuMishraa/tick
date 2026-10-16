#!/bin/bash
# Builds the release bundle (scripts/bundle.sh release) and packages it as
# tick.dmg, also copied to web/public for the download link.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/bundle.sh release
APP="target/bundle/release/tick.app"

STAGING="target/dmg_root"
rm -rf "$STAGING" ./*.dmg
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname tick -srcfolder "$STAGING" -ov -format UDZO ./tick.dmg
rm -rf "$STAGING"

mkdir -p web/public
cp ./tick.dmg web/public/tick.dmg
echo "Built tick.dmg (also copied to web/public/tick.dmg)"
