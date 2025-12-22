import Foundation
import IOKit.hid
import os

extension Notification.Name {
    static let didReceiveBatteryLevel = Notification.Name("didReceiveBatteryLevel")
}

// MARK: - Battery Command Model
private struct BatteryCommand {
    let reportId: UInt8
    let data: [UInt8]
    let description: String
}

class HIDManager {
    // MARK: - Properties

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.rrazvan.keychron.battery", category: "HIDManager")
    private var manager: IOHIDManager?
    private let reportSize = 64 // K2 HE uses 64-byte reports
    private var deviceBuffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:] // Keep buffers alive
    private var rawHIDDevice: IOHIDDevice?
    private var isSearchingForBattery = false

    private let commandSequence: [BatteryCommand] = [
            // 1. VIA/QMK Standard
            BatteryCommand(reportId: 0,
                           data: [0x04, 0xB0] + [UInt8](repeating: 0x00, count: 62),
                           description: "VIA Get Value (0x04)"),

            // 2. Apple Standard Battery Request
            BatteryCommand(reportId: 0,
                           data: [0x02] + [UInt8](repeating: 0x00, count: 63),
                           description: "Standard Battery (0x02)"),

            // 3. Keychron Specific Variations
            BatteryCommand(reportId: 0,
                           data: [0x08, 0x01] + [UInt8](repeating: 0x00, count: 62),
                           description: "Keychron (0x08, 0x01)"),
            BatteryCommand(reportId: 0,
                           data: [0x08, 0x02] + [UInt8](repeating: 0x00, count: 62),
                           description: "Keychron (0x08, 0x02)"),
            BatteryCommand(reportId: 0,
                           data: [0x08, 0x0F] + [UInt8](repeating: 0x00, count: 62),
                           description: "Keychron (0x08, 0x0F)"),

            // 4. Legacy 32-byte report
            BatteryCommand(reportId: 0,
                           data: [0x02] + [UInt8](repeating: 0x00, count: 31),
                           description: "Legacy 32-byte (0x02)")
        ]

    // MARK: - Initialization

    init() {
        logger.info("🚀 HIDManager: Starting search for Keychron devices...")
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // BROAD MATCH: Match ANY device from Keychron (0x3434)
        let matchingDict: [String: Any] = [
            kIOHIDVendorIDKey: 0x3434
        ]

        guard let manager = manager else {
            logger.error("❌ HIDManager: Failed to create manager.")
            return
        }

        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)

        // Callback for when a device is matched
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.inspectDevice(device)
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.deviceRemoved(device)
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let resultString = openResult == kIOReturnSuccess ? "Success" : "Error \(openResult)"
        logger.info("📡 HIDManager: Open Result = \(resultString)")

        // NEW: Enumerate already-connected devices at startup
        if let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            logger.info("🔎 Enumerating \(deviceSet.count) already-connected HID devices at startup...")
            for device in deviceSet {
                self.inspectDevice(device)
            }
        } else {
            logger.info("🔎 No already-connected HID devices found at startup.")
        }
    }

    // MARK: - Device Discovery

    private func inspectDevice(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"

        logger.info("""
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
                    logger.info("  🔋 BATTERY ELEMENT: Page=0x\(String(format: "%04X", ePage)), Usage=0x\(String(format: "%04X", eUsage))")
                }
            }
        }

        // Keychron Raw HID is almost always Page: 0xFF60, Usage: 0x61
        if usagePage == 0xFF60 && usage == 0x61 {
            logger.info("✅ MATCH! This is the Raw HID interface. Registering receiver...")
            setupReceiver(device: device)
        }
    }

    private func setupReceiver(device: IOHIDDevice) {
        rawHIDDevice = device

        // Open the device directly
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let resultString = openResult == kIOReturnSuccess ? "Success" : "Failed (\(openResult))"
        logger.info("🔓 Opened HID device directly: \(resultString)")

        // Enumerate all HID elements to find battery-related ones
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            logger.info("📋 Found \(elements.count) HID elements:")
            for element in elements.prefix(20) {
                let usagePage = IOHIDElementGetUsagePage(element)
                let usage = IOHIDElementGetUsage(element)
                let type = IOHIDElementGetType(element)
                logger.debug("  • Page: 0x\(String(format: "%04X", usagePage)), Usage: 0x\(String(format: "%04X", usage)), Type: \(type.rawValue)")
            }
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        deviceBuffers[device] = buffer // Keep buffer alive

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Register input report callback
        IOHIDDeviceRegisterInputReportCallback(device, buffer, reportSize, { context, _, _, _, _, report, reportLength in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.handleInputReport(report: report, reportLength: reportLength)
        }, context)

        // Also register input value callback (catches different types of reports)
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.handleInputValue(value: value)
        }, context)

        // Schedule with run loop
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        logger.info("✅ Input callbacks registered with \(self.reportSize)-byte buffer")
    }

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
        let data = UnsafeBufferPointer(start: report, count: reportLength)
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("📥 HID Data Received (\(reportLength) bytes): \(hexString)")

        // Keychron can send battery info with different formats, check for common patterns
        if reportLength >= 3 {
            if data[0] == 0x02 && data[2] > 0 && data[2] <= 100 {
                let battery = Int(data[2])

                // ✅ SUCCESS!
                // Stop the retry loop immediately so we don't spam more commands
                if isSearchingForBattery {
                    logger.info("✅ Battery found (\(battery)%). Stopping scan sequence.")
                    isSearchingForBattery = false
                }

                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .didReceiveBatteryLevel, object: battery)
                }
            }
        }
    }

    private func handleInputValue(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        logger.debug("📊 Input Value - Page: 0x\(String(format: "%04X", usagePage)), Usage: 0x\(String(format: "%04X", usage)), Value: \(intValue)")
    }

    // MARK: - Memory Management
    private func deviceRemoved(_ device: IOHIDDevice) {
        logger.info("🔌 Device disconnected. Cleaning up resources.")

        // 1. Deallocate the C-pointer buffer
        if let buffer = deviceBuffers[device] {
            buffer.deallocate()
            deviceBuffers.removeValue(forKey: device)
        }

        // 2. If this was our active device, clear it
        if rawHIDDevice == device {
            rawHIDDevice = nil
        }
    }

    private func executeCommandStep(device: IOHIDDevice, index: Int) {
        let totalCommands = commandSequence.count

        guard index < totalCommands, isSearchingForBattery else {
            if index >= totalCommands {
                logger.info("🛑 HID: Finished command sequence. No response from device.")
            }
            isSearchingForBattery = false
            return
        }

        let command = commandSequence[index]
        var report = command.data

        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(command.reportId), &report, report.count)

        let success = (result == kIOReturnSuccess)
        let icon = success ? "📤" : "⚠️"
        logger.debug("\(icon) Trying [\(index + 1)/\(totalCommands)]: \(command.description)")

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.executeCommandStep(device: device, index: index + 1)
        }
    }

    deinit {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        deviceBuffers.values.forEach { $0.deallocate() }
    }

    // MARK: - Battery Communication Logic

    func requestBatteryUpdate() {
            guard let device = rawHIDDevice else { return }

            // If we are already running a sequence, don't restart it
            if isSearchingForBattery { return }

            logger.info("🔄 Starting robust battery scan sequence...")
            isSearchingForBattery = true

            // Start the chain with the first command
            executeCommandStep(device: device, index: 0)
        }
}
