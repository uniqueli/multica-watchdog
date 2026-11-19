#!/bin/bash
# multica-notify 构建: 编译 + 组装 .app (编译失败会中止)
set -e
cd "$(dirname "$0")"
swiftc -O -o MulticaWatchdog main.swift
APP=MulticaWatchdog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp MulticaWatchdog "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
echo "✅ 构建完成: $APP"
