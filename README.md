# Keychron Battery Level Monitor

A lightweight macOS menu bar application that displays the battery level of your Keychron keyboard and other Bluetooth peripherals in real-time.

![Menu Bar Preview](https://img.shields.io/badge/macOS-13.0+-blue.svg)

![Preview](./image.png)

## Features

- 🔋 **Real-time Battery Monitoring** - Shows battery percentage for connected devices in the menu bar
- 🖱️ **Multi-Device Support** - Monitor multiple devices simultaneously (Keyboards, Mice, Headphones, Gamepads)
- 🎭 **Customizable Icons** - Assign custom icons (⌨️, 🖱️, 🎮, 🎧) to each device via the menu
- 🎨 **Color-coded Display** - Battery level changes color (red ≤10%, orange ≤30%, default >30%)
- 🔄 **Auto-refresh** - Updates battery level every 5 minutes automatically
- 🚀 **Launch at Login** - Optional setting to start the app automatically when you log in
- 📡 **Bluetooth & HID** - Uses CoreBluetooth and IOKit (HID) to communicate with devices
- 🌓 **Dark Mode Support** - Menu bar icon adapts to system appearance
- 🏠 **Home Assistant Integration** - Publishes battery levels to Home Assistant via MQTT Discovery

## Requirements

- macOS 13.0 or later
- Xcode 14.0 or later (for building)
- Keychron keyboard with Bluetooth connectivity

## Installation

### Using Pre-built DMG

1. Download `KeychronBattery.dmg` from the releases
2. Open the DMG file
3. Drag the app to your Applications folder
4. Launch the app from Applications
5. Grant Bluetooth permissions when prompted

### Building from Source

See the [Building](#building) section below.

## Usage

1. **Launch the app** - The keyboard battery percentage will appear in your menu bar
2. **Click the menu bar icon** to access options:
   - **Device List** - See all connected devices and their battery levels
   - **Customize Icons** - Hover over a device in the menu to change its icon (Keyboard, Mouse, Gamepad, Headphones)
   - **Refresh Battery** - Manually update the battery level
   - **Launch at Login** - Toggle automatic startup
   - **Quit** - Exit the application

The battery level updates automatically every 5 minutes and displays as:
- `--% ` when disconnected or initializing
- `⌨️ 80%` (or configured icon) with color coding based on charge level
- Multiple devices are shown side-by-side: `⌨️ 80% 🖱️ 45%`

## Home Assistant Integration

The app can publish battery readings to Home Assistant via MQTT Discovery. Once configured, every BLE/HID peripheral the app sees appears in HA automatically as a battery sensor — no YAML, no template sensors.

### Prerequisites (HA side)

1. **Mosquitto broker** add-on installed (HA OS → Settings → Add-ons → Mosquitto broker), or any reachable MQTT broker.
2. **MQTT integration** enabled in HA — it usually auto-prompts once the broker is up.
3. A dedicated MQTT user in HA → Settings → People → Users (e.g. `mac-battery`) with a password. The app uses these credentials.

The default discovery prefix is `homeassistant` — leave it untouched.

### Configure the app

1. Click the menu bar icon → **Preferences…**
2. (Optional) Use the **Discovered** dropdown at the top to auto-fill the broker. It browses the LAN over mDNS for:
   - `_mqtt._tcp` and `_secure-mqtt._tcp` — native broker advertisements
   - `_home-assistant._tcp` — your HA instance (listed as "probable MQTT"; assumes the broker lives on the same host at port 1883)

   Pick one and the Host / Port / TLS fields are filled automatically. Pick **Manual entry** to type the values yourself — e.g. for an external broker on a NAS, or if your network doesn't propagate mDNS.

   On first use macOS will prompt for **Local Network** access — allow it, otherwise the popup just shows "Searching…" forever.
3. Fill in:
   - **Host** — `homeassistant.local`, your HA's IP, or whatever the Discovered popup filled in
   - **Port** — `1883` (default; `8883` for TLS)
   - **Username** / **Password** — the MQTT user you created above
   - **Use TLS** — only if your broker requires it
4. Click **Test Connection** to verify, then **Save**.

Within seconds you'll see entries under HA → Settings → Devices & Services → MQTT: a "bridge" device representing this Mac, plus one sub-device per peripheral, each carrying a Battery sensor.

### Data model

- Each peripheral becomes its own HA device, linked via `via_device` to the Mac bridge.
- The whole app shares a single availability topic — when the Mac/app goes offline, all entities flip to "Unavailable" together (MQTT LWT).
- States are retained, so values persist across HA restarts.

### Building from source (Home Assistant integration)

The MQTT client uses the [CocoaMQTT](https://github.com/emqx/CocoaMQTT) Swift package. Xcode resolves it automatically the first time you build (Package Dependencies are wired into the project).

## Building

### Prerequisites

- macOS 13.0 or later
- Xcode 14.0 or later
- Apple Developer account (for code signing)

### Build Steps

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd keychron-battery-level
   ```

2. **Open in Xcode**
   ```bash
   open KeychronBattery.xcodeproj
   ```

3. **Configure Signing**
   - Select the project in the navigator
   - Go to "Signing & Capabilities" tab
   - Select your development team
   - Ensure "Automatically manage signing" is enabled

4. **Build the app**
   - Select `KeychronBattery` scheme
   - Choose `Any Mac` as the destination
   - Press `⌘B` to build, or `⌘R` to build and run

5. **Run the app**
   - Press `⌘R` or click the Run button
   - Grant Bluetooth permissions when prompted

### Debug Build

For development and testing:
```bash
xcodebuild -project KeychronBattery.xcodeproj -scheme KeychronBattery -configuration Debug
```

### Release Build

For distribution:
```bash
xcodebuild -project KeychronBattery.xcodeproj -scheme KeychronBattery -configuration Release
```

The compiled app will be located at:
```
build/Release/KeychronBattery.app
```

## Creating a Release

### Method 1: Manual DMG Creation

1. **Build for Release**
   ```bash
   xcodebuild -project KeychronBattery.xcodeproj \
              -scheme KeychronBattery \
              -configuration Release \
              -derivedDataPath ./build
   ```

2. **Locate the App**
   ```bash
   cd build/Build/Products/Release
   ```

3. **Create DMG using Disk Utility**
   - Open Disk Utility
   - File → New Image → Image from Folder
   - Select the `KeychronBattery.app`
   - Save as `KeychronBattery.dmg`

### Method 2: Using Command Line

1. **Build the app** (if not already built)
   ```bash
   xcodebuild -project KeychronBattery.xcodeproj \
              -scheme KeychronBattery \
              -configuration Release \
              -derivedDataPath ./build
   ```

2. **Create a temporary directory**
   ```bash
   mkdir -p dmg-staging
   cp -R build/Build/Products/Release/KeychronBattery.app dmg-staging/
   ```

3. **Create DMG**
   ```bash
   hdiutil create -volname "Keychron Battery Monitor" \
                  -srcfolder dmg-staging \
                  -ov -format UDZO \
                  KeychronBattery.dmg
   ```

4. **Clean up**
   ```bash
   rm -rf dmg-staging
   ```

### Method 3: Using create-dmg Tool

This method creates a more polished DMG with custom styling (requires `create-dmg` tool).

1. **Install create-dmg** (if not already installed)
   ```bash
   brew install create-dmg
   ```

2. **Build the app** (if not already built)
   ```bash
   xcodebuild -project KeychronBattery.xcodeproj \
              -scheme KeychronBattery \
              -configuration Release \
              -derivedDataPath ./build
   ```

3. **Prepare staging directory**
   ```bash
   mkdir -p dmg-staging
   cp -R build/Release/KeychronBattery.app dmg-staging/
   ```

4. **Create styled DMG**
   ```bash
   create-dmg \
     --volname "KeychronBattery" \
     --volicon "KeychronBattery/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
     --window-pos 200 120 \
     --window-size 800 400 \
     --icon-size 100 \
     --icon "KeychronBattery.app" 175 120 \
     --hide-extension "KeychronBattery.app" \
     --app-drop-link 625 120 \
     "KeychronBattery_vX.X.X.dmg" \
     "dmg-staging/"
   ```

5. **Clean up**
   ```bash
   rm -rf dmg-staging
   ```

### Code Signing & Notarization (Optional)

For distribution outside of personal use:

1. **Sign the app**
   ```bash
   codesign --deep --force --verify --verbose \
            --sign "Developer ID Application: Your Name" \
            KeychronBattery.app
   ```

2. **Notarize with Apple**
   ```bash
   xcrun notarytool submit KeychronBattery.dmg \
                           --apple-id your@email.com \
                           --team-id TEAMID \
                           --password app-specific-password
   ```

3. **Staple the notarization**
   ```bash
   xcrun stapler staple KeychronBattery.dmg
   ```

## GitHub Releases with Actions

The project includes automated releases using GitHub Actions. When you push a version tag, it automatically builds the app, creates a DMG, and publishes a GitHub release.

### Creating a New Release

1. **Commit all changes**
   ```bash
   git add .
   git commit -m "Release version 1.0.0"
   ```

2. **Create and push a version tag**
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. **GitHub Actions will automatically**:
   - Build the app for macOS
   - Create a DMG file named `KeychronBattery-v1.0.0.dmg`
   - Create a GitHub release with the DMG attached
   - Add release notes automatically

4. **View the release** - Go to your GitHub repository → Releases tab (right sidebar)

### Version Numbering

Follow semantic versioning (MAJOR.MINOR.PATCH):
- `v1.0.0` - Initial release
- `v1.0.1` - Bug fixes
- `v1.1.0` - New features (backwards compatible)
- `v2.0.0` - Breaking changes

### Manual Release Steps

If you prefer not to use GitHub Actions, you can create releases manually:

1. Build and create the DMG (see [Creating a Release](#creating-a-release))
2. Go to your GitHub repository → Releases → Draft a new release
3. Create a new tag (e.g., `v1.0.0`)
4. Upload the DMG file
5. Add release notes
6. Publish release

## Project Structure

```
KeychronBattery/
├── AppDelegate.swift                  # Main app delegate and menu bar setup
├── BluetoothBatteryHelper.swift       # CoreBluetooth battery monitoring
├── HIDManager.swift                   # HID device management (alternative method)
├── StatusMenuController.swift         # Menu bar UI
├── HomeAssistantPublisher.swift       # MQTT client + HA Discovery (optional)
├── PreferencesWindowController.swift  # Preferences window
├── KeychronCredentials.swift          # Keychain helpers for MQTT password
├── Info.plist                         # App configuration and permissions
├── KeychronBattery.entitlements       # Bluetooth + network.client entitlements
└── Assets.xcassets/                   # App icons and menu bar icon
```

## Troubleshooting

### Battery Level Shows "--%" 

- Ensure your Keychron keyboard is connected via Bluetooth
- Check that Bluetooth is enabled on your Mac
- Try clicking "Refresh Battery" from the menu
- Verify the app has Bluetooth permissions in System Settings → Privacy & Security → Bluetooth

### App Doesn't Launch at Login

- Re-toggle the "Launch at Login" option
- Check System Settings → General → Login Items
- Ensure the app is in your Applications folder

### Permission Denied

- Grant Bluetooth access in System Settings → Privacy & Security → Bluetooth
- Restart the app after granting permissions

## Technical Details

- **Language**: Swift
- **Frameworks**: CoreBluetooth, IOKit, ServiceManagement
- **Architecture**: Universal (Apple Silicon & Intel)
- **Minimum Target**: macOS 13.0

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Created by Razvan
