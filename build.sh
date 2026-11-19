#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build/Hop.app/Contents/MacOS
swiftc checks/main.swift Sources/Fuzzy.swift Sources/Calculator.swift -o build/check && build/check
cp Info.plist build/Hop.app/Contents/
swiftc -O Sources/*.swift -o build/Hop.app/Contents/MacOS/Hop
codesign -s - --force build/Hop.app
if [ "$1" = "install" ]; then
  pkill -x Hop || true
  rm -rf ~/Applications/Hop.app && mkdir -p ~/Applications && cp -R build/Hop.app ~/Applications/
  open ~/Applications/Hop.app
fi
