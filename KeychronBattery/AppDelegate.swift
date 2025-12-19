//
//  AppDelegate.swift
//  KeychronBattery
//
//  Created by Razvan on 19.12.2025.
//

import Cocoa
import ServiceManagement
import os

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.keychron.battery", category: "AppDelegate")
    var statusItem: NSStatusItem?
    let bluetoothMonitor = BluetoothBatteryMonitor()
    let hidManager = HIDManager()
    private var startupRetryCount = 0
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Create the Menu Bar Item with custom icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Use custom icon from assets, sized for menu bar
            if let customIcon = NSImage(named: "MenuBarIcon") {
                customIcon.isTemplate = true // Makes it adapt to light/dark mode
                customIcon.size = NSSize(width: 18, height: 18) // Resize to standard menu bar size
                button.image = customIcon
            }
            button.title = " --%"
        }
        
        // 2. Build the Menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh Battery", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        
        // Add Launch at Login toggle
        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        
        // 3. Listen for battery updates from Bluetooth
        NotificationCenter.default.addObserver(forName: .didUpdateBluetoothBattery, object: nil, queue: .main) { [weak self] notification in
            if let level = notification.object as? Int {
                self?.logger.info("Received Bluetooth battery update: \(level)%")
                self?.updateBatteryDisplay(level: level)
            }
        }
        
        // 4. Listen for battery updates from HID (Wired)
        NotificationCenter.default.addObserver(forName: .didReceiveBatteryLevel, object: nil, queue: .main) { [weak self] notification in
            if let level = notification.object as? Int {
                self?.logger.info("Received HID battery update: \(level)%")
                self?.updateBatteryDisplay(level: level)
            }
        }
        
        // 5. Start Bluetooth monitoring after app is fully launched
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.bluetoothMonitor.start()
            self.scheduleStartupRetries()
        }
        
        // 6. Auto-refresh every 5 minutes (Bluetooth is less battery intensive)
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    
    private func scheduleStartupRetries() {
        // Retry every 10 seconds for the first 2 minutes (12 times) to catch devices connecting after boot
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.startupRetryCount += 1
            
            if self.startupRetryCount > 12 {
                timer.invalidate()
                self.logger.info("Startup retries finished.")
            } else {
                self.logger.info("Startup retry #\(self.startupRetryCount)")
                self.refresh()
            }
        }
    }
    
    @objc func refresh() {
        logger.info("Refreshing battery status...")
        bluetoothMonitor.requestBatteryUpdate()
        hidManager.requestBatteryUpdate()
    }
    
    private func updateBatteryDisplay(level: Int) {
        guard let button = statusItem?.button else { return }
        
        let displayText = level >= 0 ? " \(level)%" : " --%"
        
        // Apply color based on battery level
        let color: NSColor
        if level < 0 {
            color = .labelColor // Default system color
        } else if level <= 10 {
            color = .systemRed
        } else if level <= 30 {
            color = .systemOrange
        } else {
            color = .labelColor // Default system color
        }
        
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.menuBarFont(ofSize: 0) // Use system menu bar font size
        ]
        
        button.attributedTitle = NSAttributedString(string: displayText, attributes: attributes)
    }
    
    // MARK: - Launch at Login
    
    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if isLaunchAtLoginEnabled() {
            disableLaunchAtLogin()
            sender.state = .off
        } else {
            enableLaunchAtLogin()
            sender.state = .on
        }
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        
        // Fallback for older macOS: Check launchctl list
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains(bundleId)
            }
        } catch {
            logger.error("Failed to check launchctl: \(error.localizedDescription)")
        }
        
        return false
    }
    
    func enableLaunchAtLogin() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        
        if #available(macOS 13.0, *) {
            // Use modern API for macOS 13+
            do {
                try SMAppService.mainApp.register()
                logger.info("✅ Enabled launch at login")
            } catch {
                logger.error("❌ Failed to enable launch at login: \(error.localizedDescription)")
            }
        } else {
            // Fallback for older macOS
            let success = SMLoginItemSetEnabled(bundleId as CFString, true)
            if success {
                logger.info("✅ Enabled launch at login")
            } else {
                logger.error("❌ Failed to enable launch at login")
            }
        }
    }
    
    func disableLaunchAtLogin() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        
        if #available(macOS 13.0, *) {
            // Use modern API for macOS 13+
            do {
                try SMAppService.mainApp.unregister()
                logger.info("✅ Disabled launch at login")
            } catch {
                logger.error("❌ Failed to disable launch at login: \(error.localizedDescription)")
            }
        } else {
            // Fallback for older macOS
            let success = SMLoginItemSetEnabled(bundleId as CFString, false)
            if success {
                logger.info("✅ Disabled launch at login")
            } else {
                logger.error("❌ Failed to disable launch at login")
            }
        }
    }
}
