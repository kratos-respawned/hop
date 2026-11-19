#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build/Hop.app/Contents/MacOS build/Hop.app/Contents/Resources
swiftc checks/main.swift Sources/Fuzzy.swift Sources/Plugins/Math.swift -o build/check && build/check
cp Info.plist build/Hop.app/Contents/
cp Resources/Hop.icns build/Hop.app/Contents/Resources/
swiftc -O Sources/*.swift Sources/Plugins/*.swift -o build/Hop.app/Contents/MacOS/Hop
# A real identity keeps the same designated requirement across builds, so macOS keeps Hop's permissions.
identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')
codesign -s "${identity:--}" --force build/Hop.app
if [ "$1" = "install" ]; then
  pkill -x Hop || true
  rm -rf ~/Applications/Hop.app && mkdir -p ~/Applications && cp -R build/Hop.app ~/Applications/
  open ~/Applications/Hop.app
fi
