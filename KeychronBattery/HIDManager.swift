import Foundation
import IOKit.hid

extension Notification.Name {
    static let didReceiveBatteryLevel = Notification.Name("didReceiveBatteryLevel")
}

class HIDManager {
    private var manager: IOHIDManager?
    private let reportSize = 64 // K2 HE uses 64-byte reports
    private var deviceBuffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:] // Keep buffers alive
    private var rawHIDDevice: IOHIDDevice?
    
    init() {
        print("🚀 HIDManager: Starting search for Keychron devices...")
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        // BROAD MATCH: Match ANY device from Keychron (0x3434)
        let matchingDict: [String: Any] = [
            kIOHIDVendorIDKey: 0x3434
        ]
        
        guard let manager = manager else {
            print("❌ HIDManager: Failed to create manager.")
            return
        }
        
        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        
        // Callback for when a device is matched
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.inspectDevice(device)
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        print("📡 HIDManager: Open Result = \(openResult == kIOReturnSuccess ? "Success" : "Error \(openResult)")")
    }
    
    private func inspectDevice(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"
        
        print("""
        -----------------------------------------
        🔍 Found Device: \(name)
           PID: \(String(format: "0x%04X", pid))
           Transport: \(transport)
           Usage Page: \(String(format: "0x%04X", usagePage))
           Usage ID: \(String(format: "0x%04X", usage))
        -----------------------------------------
        """)
        
        // Check ALL devices for battery elements
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for element in elements {
                let ePage = IOHIDElementGetUsagePage(element)
                let eUsage = IOHIDElementGetUsage(element)
                // Battery System (0x85) or Power Device (0x84)
                if ePage == 0x85 || ePage == 0x84 {
                    print("  🔋 BATTERY ELEMENT: Page=0x\(String(format: "%04X", ePage)), Usage=0x\(String(format: "%04X", eUsage))")
                }
            }
        }

        // Keychron Raw HID is almost always Page: 0xFF60, Usage: 0x61
        if usagePage == 0xFF60 && usage == 0x61 {
            print("✅ MATCH! This is the Raw HID interface. Registering receiver...")
            setupReceiver(device: device)
        }
    }
    
    private func setupReceiver(device: IOHIDDevice) {
        rawHIDDevice = device
        
        // Open the device directly
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        print("🔓 Opened HID device directly: \(openResult == kIOReturnSuccess ? "Success" : "Failed (\(openResult))")")
        
        // Enumerate all HID elements to find battery-related ones
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            print("📋 Found \(elements.count) HID elements:")
            for element in elements.prefix(20) {
                let usagePage = IOHIDElementGetUsagePage(element)
                let usage = IOHIDElementGetUsage(element)
                let type = IOHIDElementGetType(element)
                print("  • Page: 0x\(String(format: "%04X", usagePage)), Usage: 0x\(String(format: "%04X", usage)), Type: \(type.rawValue)")
            }
        }
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        deviceBuffers[device] = buffer // Keep buffer alive
        
        // Register input report callback
        IOHIDDeviceRegisterInputReportCallback(device, buffer, reportSize, { context, result, sender, type, reportId, report, reportLength in
            let data = UnsafeBufferPointer(start: report, count: reportLength)
            print("📥 HID Data Received (\(reportLength) bytes): \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            
            // Keychron can send battery info with different formats, check for common patterns
            if reportLength >= 3 {
                // Try different byte positions where battery might be
                for i in 0..<min(reportLength, 10) {
                    if data[i] > 0 && data[i] <= 100 {
                        print("🔋 Potential battery at byte \(i): \(data[i])%")
                    }
                }
                
                // Common pattern: 0x02 command response
                if data[0] == 0x02 && reportLength > 2 {
                    let battery = Int(data[2])
                    print("🔋 Battery Level Parsed (offset 2): \(battery)%")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .didReceiveBatteryLevel, object: battery)
                    }
                }
            }
        }, nil)
        
        // Also register input value callback (catches different types of reports)
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, sender, value in
            let element = IOHIDValueGetElement(value)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let intValue = IOHIDValueGetIntegerValue(value)
            print("📊 Input Value - Page: 0x\(String(format: "%04X", usagePage)), Usage: 0x\(String(format: "%04X", usage)), Value: \(intValue)")
        }, nil)
        
        // Schedule with run loop
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        
        print("✅ Input callbacks registered with \(reportSize)-byte buffer")
    }
    
    func requestBatteryUpdate() {
        guard let device = rawHIDDevice else {
            print("⚠️ Raw HID device not available yet")
            return
        }
        
        print("\n🔄 Attempting battery update...")
        
        // Try VIA/QMK protocol commands for battery
        let commandTests: [(reportId: UInt8, data: [UInt8], desc: String)] = [
            // Standard battery request
            (0, [0x02] + [UInt8](repeating: 0x00, count: reportSize - 1), "Standard 0x02"),
            // VIA protocol: Get keyboard value
            (0, [0x04, 0xB0] + [UInt8](repeating: 0x00, count: reportSize - 2), "VIA Get Value"),
            // Try Keychron-specific commands
            (0, [0x08, 0x01] + [UInt8](repeating: 0x00, count: reportSize - 2), "Keychron 0x08,0x01"),
            (0, [0x08, 0x02] + [UInt8](repeating: 0x00, count: reportSize - 2), "Keychron 0x08,0x02"),
            (0, [0x08, 0x0F] + [UInt8](repeating: 0x00, count: reportSize - 2), "Keychron 0x08,0x0F"),
            // Try raw 32-byte variant (some Keychrons use 32)
            (0, [0x02] + [UInt8](repeating: 0x00, count: 31), "0x02 32-byte"),
        ]
        
        for test in commandTests {
            var report = test.data
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(test.reportId), &report, report.count)
            print("📤 \(test.desc): \(result == kIOReturnSuccess ? "✓" : "✗")")
            usleep(100000) // 100ms between attempts - give more time for response
        }
        
        print("\n⏳ Waiting 2 seconds for any delayed responses...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("⏰ Wait complete. Check if any data was received above.")
        }
    }
}
