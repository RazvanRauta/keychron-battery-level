//
//  AppDelegate.swift
//  KeychronBattery
//
//  Created by Razvan on 19.12.2025.
//

import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let bluetoothMonitor = BluetoothBatteryMonitor()
    
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
        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        
        // 3. Listen for battery updates from Bluetooth
        NotificationCenter.default.addObserver(forName: .didUpdateBluetoothBattery, object: nil, queue: .main) { notification in
            if let level = notification.object as? Int {
                self.updateBatteryDisplay(level: level)
            }
        }
        
        // 4. Start Bluetooth monitoring after app is fully launched
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.bluetoothMonitor.start()
        }
        
        // 5. Auto-refresh every 5 minutes (Bluetooth is less battery intensive)
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.refresh()
        }
    }
    
    @objc func refresh() {
        bluetoothMonitor.requestBatteryUpdate()
    }
    
    private func updateBatteryDisplay(level: Int) {
        guard let button = statusItem?.button else { return }
        
        // Keep the keyboard icon, just update the text
        button.title = level >= 0 ? " \(level)%" : " --%"
    }
    
    // MARK: - Launch at Login
    
    @objc func toggleLaunchAtLogin() {
        if isLaunchAtLoginEnabled() {
            disableLaunchAtLogin()
        } else {
            enableLaunchAtLogin()
        }
        
        // Update menu item state
        if let menu = statusItem?.menu {
            for item in menu.items {
                if item.title == "Launch at Login" {
                    item.state = isLaunchAtLoginEnabled() ? .on : .off
                }
            }
        }
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        
        // Check if app is in Login Items
        let jobDicts = SMCopyAllJobDictionaries(kSMDomainUserLaunchd).takeRetainedValue() as? [[String: Any]] ?? []
        return jobDicts.contains { dict in
            (dict["Label"] as? String) == bundleId
        }
    }
    
    func enableLaunchAtLogin() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        
        if #available(macOS 13.0, *) {
            // Use modern API for macOS 13+
            do {
                try SMAppService.mainApp.register()
                print("✅ Enabled launch at login")
            } catch {
                print("❌ Failed to enable launch at login: \(error)")
            }
        } else {
            // Fallback for older macOS
            let success = SMLoginItemSetEnabled(bundleId as CFString, true)
            print(success ? "✅ Enabled launch at login" : "❌ Failed to enable launch at login")
        }
    }
    
    func disableLaunchAtLogin() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        
        if #available(macOS 13.0, *) {
            // Use modern API for macOS 13+
            do {
                try SMAppService.mainApp.unregister()
                print("✅ Disabled launch at login")
            } catch {
                print("❌ Failed to disable launch at login: \(error)")
            }
        } else {
            // Fallback for older macOS
            let success = SMLoginItemSetEnabled(bundleId as CFString, false)
            print(success ? "✅ Disabled launch at login" : "❌ Failed to disable launch at login")
        }
    }
}
