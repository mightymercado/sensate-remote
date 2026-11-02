#!/bin/bash
# Builds the Mac BLE helper app (SensateCtl.app). First run triggers a one-time
# macOS Bluetooth permission prompt — click Allow.
set -e
cd "$(dirname "$0")"
swiftc -O -o sensatectl-bin sensatectl.swift
mkdir -p SensateCtl.app/Contents/MacOS
cp sensatectl-bin SensateCtl.app/Contents/MacOS/sensatectl
cat > SensateCtl.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>sensatectl</string>
  <key>CFBundleIdentifier</key><string>local.sensate.SensateCtl</string>
  <key>CFBundleName</key><string>SensateCtl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSBackgroundOnly</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Controls your Sensate 2 relaxation device over Bluetooth.</string>
</dict>
</plist>
PLIST
touch SensateCtl.app
echo "Built. Usage: open -n SensateCtl.app --args status|start|stop   (result in ~/.sensatectl-last.json)"
