#!/bin/sh

set -eu

label="com.dannystewart.swiftboard"
app_dir="$HOME/Applications"
app="$app_dir/Swiftboard.app"
executable="$app/Contents/MacOS/Swiftboard"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
peer="${1:-}"

if [ "$peer" = "--uninstall" ]; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
    pkill -x Swiftboard 2>/dev/null || true
    rm -f "$plist"
    rm -rf "$app" "$HOME/Library/Application Support/Swiftboard"
    defaults delete "$label" 2>/dev/null || true
    printf 'Swiftboard uninstalled.\n'
    exit 0
fi

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$repo_dir/.build/xcode-install"
built_app="$derived_data/Build/Products/Release/Swiftboard.app"

printf 'Building and signing Swiftboard.app...\n'
xcodebuild \
    -project "$repo_dir/Swiftboard.xcodeproj" \
    -scheme Swiftboard \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    build

mkdir -p "$app_dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$domain/$label" 2>/dev/null || true
pkill -x Swiftboard 2>/dev/null || true
rm -rf "$app"
/usr/bin/ditto "$built_app" "$app"
codesign --verify --deep --strict "$app"

if [ -n "$peer" ]; then
    defaults write "$label" peer -string "$peer"
else
    defaults delete "$label" peer 2>/dev/null || true
fi

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$label</string>
    </array>
    <key>ProgramArguments</key>
    <array>
        <string>$executable</string>
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

printf 'Swiftboard.app installed and running. Log: %s\n' "$HOME/Library/Logs/swiftboard.log"
printf 'Allow Swiftboard Local Network access when macOS prompts.\n'
if [ -n "$peer" ]; then
    printf 'Configured peer: %s\n' "$peer"
fi
printf 'Run sh %s --uninstall to remove it.\n' "$0"
