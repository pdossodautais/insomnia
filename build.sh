#!/bin/sh
# Builds Insomnia.app, installs it in /Applications, links the `insomnia` command
# and leaves a shareable build/Insomnia.zip.
set -e
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install
    echo "Install the Command Line Tools in the window that opened, then run build.sh again."
    exit 1
fi

APP=build/Insomnia.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The default SDK can be newer than the compiler: then use the newest SDK it accepts.
compile() { swiftc ${1:+-sdk "$1"} -O -o "$APP/Contents/MacOS/Insomnia" main.swift 2>build/errors.log; }
if ! compile; then
    for sdk in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
        compile "$sdk" && break
    done
fi
[ -x "$APP/Contents/MacOS/Insomnia" ] || { cat build/errors.log; exit 1; }

cp -R Resources/* "$APP/Contents/Resources/"
# Every Resources/<lang>.lproj folder is a supported language, besides built-in English.
LANGUAGES="<string>en</string>$(for d in Resources/*.lproj; do printf '<string>%s</string>' "$(basename "$d" .lproj)"; done)"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.insomnia</string>
  <key>CFBundleName</key><string>Insomnia</string>
  <key>CFBundleExecutable</key><string>Insomnia</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>$LANGUAGES</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null
ditto -c -k --keepParent "$APP" build/Insomnia.zip

pkill -x Insomnia 2>/dev/null && sleep 1 || true
rm -rf /Applications/Insomnia.app
cp -R "$APP" /Applications/
echo "Installed: /Applications/Insomnia.app"

# Command-line tool: first writable folder among the usual ones, else ~/.local/bin.
for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    [ -w "$dir" ] && break
done
[ -w "$dir" ] || mkdir -p "$dir"
ln -sf /Applications/Insomnia.app/Contents/MacOS/Insomnia "$dir/insomnia"
echo "Command:   $dir/insomnia"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "Add it to your PATH: echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc" ;;
esac

open /Applications/Insomnia.app
