#!/bin/sh

set -eu

label="com.dannystewart.swiftboard"
install_dir="$HOME/Library/Application Support/Swiftboard"
executable="$install_dir/swiftboard"
identity_marker="$install_dir/.signed-identity"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
peer="${1:-}"
signing_identity="Apple Development: Danny Stewart (75GS56XYDQ)"

if [ "$peer" = "--uninstall" ]; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
    pkill -x swiftboard 2>/dev/null || true
    rm -f "$plist"
    rm -rf "$install_dir" "$HOME/Applications/Swiftboard.app"
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

first_signed_install=false
if [ ! -f "$identity_marker" ]; then
    first_signed_install=true
fi

mkdir -p "$install_dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$domain/$label" 2>/dev/null || true
pkill -x swiftboard 2>/dev/null || true
install -m 755 "$bin_dir/swiftboard" "$executable"
if ! security find-identity -v -p codesigning | grep -F "$signing_identity" >/dev/null; then
    printf 'Code-signing identity not found: %s\n' "$signing_identity" >&2
    exit 1
fi
codesign --force --sign "$signing_identity" --identifier "$label" --timestamp=none "$executable"
codesign --verify --strict "$executable"
touch "$identity_marker"
rm -rf "$HOME/Applications/Swiftboard.app"
if [ "$first_signed_install" = true ]; then
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
if [ "$first_signed_install" = true ]; then
    printf 'Allow Swiftboard Local Network access when macOS prompts.\n'
fi
if [ -n "$peer" ]; then
    printf 'Configured peer: %s\n' "$peer"
fi
printf 'Run sh %s --uninstall to remove it.\n' "$0"
