import Cocoa

class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem!
    private let batteryIconSize = NSSize(width: 18, height: 18)

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

    func updateBatteryDisplay(level: Int) {
        guard let button = statusItem.button else { return }

        let displayText = level >= 0 ? " \(level)%" : " --%"

        let color: NSColor
        switch level {
        case ..<0:   color = .labelColor
        case 0...10: color = .systemRed
        case 11...30: color = .systemOrange
        default:     color = .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.menuBarFont(ofSize: 0)
        ]

        button.attributedTitle = NSAttributedString(string: displayText, attributes: attributes)
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
}
