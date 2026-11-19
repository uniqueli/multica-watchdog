#!/bin/bash
# multica-notify 构建: 编译 + 组装 .app (编译失败会中止)
set -e
cd "$(dirname "$0")"
swiftc -O -target arm64-apple-macos13 -o /tmp/wd-arm64 main.swift
swiftc -O -target x86_64-apple-macos13 -o /tmp/wd-x64 main.swift
lipo -create /tmp/wd-arm64 /tmp/wd-x64 -o MulticaWatchdog
APP=MulticaWatchdog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp MulticaWatchdog "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - --identifier com.uniqueli.multica-watchdog "$APP" 2>/dev/null || true
mkdir -p "$APP/Contents/Resources"
cp -r assets/* "$APP/Contents/Resources/"
echo "✅ 构建完成: $APP"
