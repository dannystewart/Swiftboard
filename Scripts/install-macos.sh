#!/bin/sh

set -eu

label="com.dannystewart.swiftboard"
app="$HOME/Applications/Swiftboard.app"
contents="$app/Contents"
executable="$contents/MacOS/swiftboard"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
peer="${1:-}"
signing_identity="Apple Development: Danny Stewart (75GS56XYDQ)"

if [ "$peer" = "--uninstall" ]; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
    pkill -x swiftboard 2>/dev/null || true
    rm -f "$plist"
    rm -rf "$app" "$HOME/Library/Application Support/Swiftboard"
    printf 'Swiftboard uninstalled.\n'
    exit 0
fi

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

printf 'Building Swiftboard...\n'
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
escaped_executable=$(printf '%s' "$executable" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
peer_argument=""
if [ -n "$peer" ]; then
    escaped_peer=$(printf '%s' "$peer" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    peer_argument="        <string>$escaped_peer</string>"
fi

first_app_install=false
if [ ! -d "$app" ]; then
    first_app_install=true
fi

mkdir -p "$contents/MacOS" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$domain/$label" 2>/dev/null || true
pkill -x swiftboard 2>/dev/null || true
install -m 755 "$bin_dir/swiftboard" "$executable"

cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>swiftboard</string>
    <key>CFBundleIdentifier</key>
    <string>$label</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Swiftboard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Swiftboard syncs the clipboard with your other computer on the local network.</string>
</dict>
</plist>
EOF

plutil -lint "$contents/Info.plist" >/dev/null
if ! security find-identity -v -p codesigning | grep -F "$signing_identity" >/dev/null; then
    printf 'Code-signing identity not found: %s\n' "$signing_identity" >&2
    exit 1
fi
codesign --force --sign "$signing_identity" --identifier "$label" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
rm -f "$HOME/Library/Application Support/Swiftboard/swiftboard"
rmdir "$HOME/Library/Application Support/Swiftboard" 2>/dev/null || true

launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$launch_services" -f "$app"
if [ "$first_app_install" = true ]; then
    tccutil reset LocalNetwork "$label" 2>/dev/null || true
fi

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$escaped_executable</string>
$peer_argument
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF

plutil -lint "$plist" >/dev/null
launchctl bootstrap "$domain" "$plist"
launchctl kickstart -k "$domain/$label"

printf 'Swiftboard installed and running. Log: %s\n' "$HOME/Library/Logs/swiftboard.log"
if [ "$first_app_install" = true ]; then
    printf 'Allow Swiftboard Local Network access when macOS prompts.\n'
fi
if [ -n "$peer" ]; then
    printf 'Configured peer: %s\n' "$peer"
fi
printf 'Run sh %s --uninstall to remove it.\n' "$0"
