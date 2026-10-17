#!/bin/sh

set -eu

label="com.dannystewart.swiftboard"
app_dir="$HOME/Applications"
app="$app_dir/Swiftboard.app"
executable="$app/Contents/MacOS/Swiftboard"
plist="$HOME/Library/LaunchAgents/$label.plist"
uid=$(id -u)
domain="gui/$uid"
service="$domain/$label"
peer="${1:-}"

launchd_diagnostics() {
    launchctl print "$service" >&2 || true
    launchctl print-disabled "$domain" >&2 || true
}

stop_swiftboard() {
    # bootout can return before teardown finishes. Do not replace the bundle
    # or bootstrap the same label until both the job and process are gone.
    launchctl bootout "$service" 2>/dev/null || true
    pkill -u "$uid" -x Swiftboard 2>/dev/null || true
    stop_attempt=0
    while :; do
        job_loaded=0
        process_running=0
        if launchctl print "$service" >/dev/null 2>&1; then
            job_loaded=1
        fi
        if pgrep -u "$uid" -x Swiftboard >/dev/null 2>&1; then
            process_running=1
        fi
        if [ "$job_loaded" -eq 0 ] && [ "$process_running" -eq 0 ]; then
            return 0
        fi
        if [ "$stop_attempt" -ge 15 ]; then
            printf 'Could not stop the existing Swiftboard job and process.\n' >&2
            launchd_diagnostics
            return 1
        fi
        if [ "$stop_attempt" -ge 5 ] && [ "$process_running" -eq 1 ]; then
            pkill -KILL -u "$uid" -x Swiftboard 2>/dev/null || true
        fi
        if [ "$job_loaded" -eq 1 ]; then
            launchctl bootout "$service" 2>/dev/null || true
        fi
        sleep 1
        stop_attempt=$((stop_attempt + 1))
    done
}

if [ "$peer" = "--uninstall" ]; then
    stop_swiftboard
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
stop_swiftboard
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
chmod 644 "$plist"
# A previous launchctl disable persists even after the plist is replaced.
launchctl enable "$service"
bootstrap_attempt=1
until launchctl bootstrap "$domain" "$plist"; do
    if [ "$bootstrap_attempt" -ge 3 ]; then
        printf 'Could not register Swiftboard after %s attempts.\n' "$bootstrap_attempt" >&2
        launchd_diagnostics
        exit 1
    fi
    printf 'Registration failed; clearing stale Swiftboard state and retrying...\n' >&2
    stop_swiftboard
    sleep "$bootstrap_attempt"
    bootstrap_attempt=$((bootstrap_attempt + 1))
done
# RunAtLoad may already have started it; do not kill that fresh process.
launchctl kickstart "$service"

printf 'Swiftboard.app installed and running. Log: %s\n' "$HOME/Library/Logs/swiftboard.log"
printf 'Allow Swiftboard Local Network access when macOS prompts.\n'
if [ -n "$peer" ]; then
    printf 'Configured peer: %s\n' "$peer"
fi
printf 'Run sh %s --uninstall to remove it.\n' "$0"
