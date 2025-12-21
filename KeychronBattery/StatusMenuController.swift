import Cocoa

class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem!
    private let batteryIconSize = NSSize(width: 18, height: 18)

    private struct DeviceInfo {
        let name: String
        var level: Int
        var iconName: String
    }

    private var devices: [String: DeviceInfo] = [:]
    private var deviceMenuItems: [String: NSMenuItem] = [:]
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        setupStatusItem()
        setupMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Setup default icon state
            if let customIcon = NSImage(named: "MenuBarIcon") {
                customIcon.isTemplate = true
                customIcon.size = batteryIconSize
                button.image = customIcon
            }
            button.title = " --%"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Refresh Item
        let refreshItem = NSMenuItem(title: "Refresh Battery", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login Item
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchClicked(_:)), keyEquivalent: "")
        launchItem.target = self
        // Set initial state based on delegate's logic
        launchItem.state = (appDelegate?.isLaunchAtLoginEnabled() ?? false) ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // Quit Item
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func updateBatteryDisplay(uuid: String, name: String, level: Int) {
        guard statusItem.button != nil else { return }

        // Load saved icon preference or default to keyboard
        let savedIcon = UserDefaults.standard.string(forKey: "icon_\(uuid)") ?? "keyboard"

        devices[uuid] = DeviceInfo(name: name, level: level, iconName: savedIcon)
        updateDeviceMenuItem(uuid: uuid)
        updateMainStatusItem()
    }

    private func updateDeviceMenuItem(uuid: String) {
        guard let info = devices[uuid], let menu = statusItem.menu else { return }

        let title = "\(iconForName(info.iconName)) \(info.name): \(info.level >= 0 ? "\(info.level)%" : "Disconnected")"

        if let existingItem = deviceMenuItems[uuid] {
            existingItem.title = title
        } else {
            // Create new item
            let newItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            newItem.indentationLevel = 0

            // Add Icon Submenu
            let submenu = NSMenu()
            let icons = ["keyboard": "Keyboard", "mouse": "Mouse", "gamecontroller": "Gamepad", "headphones": "Headphones"]

            for (iconKey, iconLabel) in icons {
                let iconItem = NSMenuItem(title: iconLabel, action: #selector(changeIconClicked(_:)), keyEquivalent: "")
                iconItem.target = self
                iconItem.representedObject = ["uuid": uuid, "icon": iconKey]
                iconItem.state = (info.iconName == iconKey) ? .on : .off
                submenu.addItem(iconItem)
            }

            newItem.submenu = submenu

            // Insert before the first separator (keeping Refresh/Quit at bottom)
            let index = menu.items.firstIndex(where: { $0.isSeparatorItem }) ?? 0
            menu.insertItem(newItem, at: index)
            deviceMenuItems[uuid] = newItem
        }
    }

    private func updateMainStatusItem() {
        guard let button = statusItem.button else { return }

        // Get all active devices sorted by name
        let activeDevices = devices.values.filter { $0.level >= 0 }.sorted(by: { $0.name < $1.name })

        // Set tooltip to show all devices on hover
        let tooltipLines = activeDevices.map { "\(iconForName($0.iconName)) \($0.name): \($0.level)%" }
        button.toolTip = tooltipLines.isEmpty ? nil : tooltipLines.joined(separator: "\n")

        if activeDevices.isEmpty {
            button.title = " --%"
            // Reset to default icon if no devices
            if let customIcon = NSImage(named: "MenuBarIcon") {
                customIcon.isTemplate = true
                customIcon.size = batteryIconSize
                button.image = customIcon
            }
            return
        }

        // Build attributed string with all devices
        let fullAttributedTitle = NSMutableAttributedString()

        for (index, device) in activeDevices.enumerated() {
            if index > 0 {
                fullAttributedTitle.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.menuBarFont(ofSize: 0)]))
            }

            let color: NSColor
            switch device.level {
            case ..<0:    color = .labelColor
            case 0...10:  color = .systemRed
            case 11...30: color = .systemOrange
            default:      color = .labelColor
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.menuBarFont(ofSize: 0)
            ]

            let text = "\(iconForName(device.iconName)) \(device.level)%"
            fullAttributedTitle.append(NSAttributedString(string: text, attributes: attributes))
        }

        button.image = nil // Clear image to rely on emoji in text
        button.attributedTitle = fullAttributedTitle
    }

    private func iconForName(_ name: String) -> String {
        switch name {
        case "keyboard": return "⌨️"
        case "mouse": return "🖱️"
        case "gamecontroller": return "🎮"
        case "headphones": return "🎧"
        default: return "🔋"
        }
    }

    @objc private func refreshClicked() {
        appDelegate?.refresh()
    }

    @objc private func toggleLaunchClicked(_ sender: NSMenuItem) {
        guard let delegate = appDelegate else { return }

        if delegate.isLaunchAtLoginEnabled() {
            delegate.disableLaunchAtLogin()
            sender.state = .off
        } else {
            delegate.enableLaunchAtLogin()
            sender.state = .on
        }
    }

    @objc private func changeIconClicked(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String],
              let uuid = data["uuid"],
              let icon = data["icon"] else { return }

        UserDefaults.standard.set(icon, forKey: "icon_\(uuid)")

        // Update model
        if var info = devices[uuid] {
            info.iconName = icon
            devices[uuid] = info
            updateDeviceMenuItem(uuid: uuid)
            updateMainStatusItem()
        }

        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
    }
}
