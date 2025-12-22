import Foundation
import CoreBluetooth
import os

extension Notification.Name {
    static let didUpdateBluetoothBattery = Notification.Name("didUpdateBluetoothBattery")
}

class BluetoothBatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.rrazvan.keychron.battery", category: "BluetoothMonitor")
    private var centralManager: CBCentralManager!
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

    // Common services to detect devices that are connected but might not expose Battery Service primarily
    private let commonServices: [CBUUID] = [
        CBUUID(string: "180F"), // Battery
        CBUUID(string: "180A"), // Device Information
        CBUUID(string: "1800"), // Generic Access
        CBUUID(string: "1801")  // Generic Attribute
    ]

    override init() {
        super.init()
        logger.info("🔵 Initializing Bluetooth Battery Monitor...")
    }

    func start() {
        // Initialize on main queue to avoid XPC issues
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logger.info("🔵 Starting CoreBluetooth Central Manager...")
            self.centralManager = CBCentralManager(
                delegate: self,
                queue: DispatchQueue.main,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("📡 Bluetooth State: \(self.stateDescription(central.state))")

        if central.state == .poweredOn {
            logger.info("🔍 Checking for connected devices...")
            // Only check for devices already connected to the system
            requestBatteryUpdate()
        } else {
            logger.warning("⚠️ Bluetooth not available")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"

        // Check if device is connectable
        if let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber, isConnectable.boolValue == false {
            return
        }

        if shouldTrackDevice(peripheral) && connectedPeripherals[peripheral.identifier] == nil {
            logger.info("✅ Found device: \(name)")
            connectToPeripheral(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("🔗 Connected to \(peripheral.name ?? "device")")
        peripheral.delegate = self
        logger.info("🔍 Discovering services...")
        // Discover all services to ensure we find Battery Service even if it's not primary
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("❌ Failed to connect to \(peripheral.name ?? "device"): \(error?.localizedDescription ?? "Unknown error")")
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("❌ Disconnected from \(peripheral.name ?? "device")")
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
        notifyBatteryUpdate(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "Unknown", level: -1)

        // Try to reconnect
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            logger.error("❌ Error discovering services: \(error!.localizedDescription)")
            return
        }

        logger.info("📋 Found \(peripheral.services?.count ?? 0) services")

        for service in peripheral.services ?? [] {
            logger.debug("  • Service: \(service.uuid)")
            if service.uuid == batteryServiceUUID {
                logger.info("    🔋 Battery Service found! Discovering characteristics...")
                peripheral.discoverCharacteristics([batteryLevelCharacteristicUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            logger.error("❌ Error discovering characteristics: \(error!.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            logger.debug("    • Characteristic: \(characteristic.uuid)")

            if characteristic.uuid == batteryLevelCharacteristicUUID {
                logger.info("      🔋 Battery Level Characteristic found!")
                // Read current value
                peripheral.readValue(for: characteristic)
                // Subscribe to notifications for battery changes
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            logger.error("❌ Error reading characteristic: \(error!.localizedDescription)")
            return
        }

        if characteristic.uuid == batteryLevelCharacteristicUUID {
            if let data = characteristic.value, let level = data.first {
                let intLevel = Int(level)
                logger.info("🔋 Battery Level [\(peripheral.name ?? "Unknown")]: \(intLevel)%")
                notifyBatteryUpdate(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "Unknown", level: intLevel)
            }
        }
    }

    // MARK: - Helper Methods

    private func shouldTrackDevice(_ peripheral: CBPeripheral) -> Bool {
        // Ensure device has a name to avoid connecting to random beacons
        return peripheral.name != nil
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        connectedPeripherals[peripheral.identifier] = peripheral
        centralManager.connect(peripheral, options: nil)
    }

    private func notifyBatteryUpdate(uuid: String, name: String, level: Int) {
        DispatchQueue.main.async {
            let userInfo: [String: Any] = [
                "uuid": uuid,
                "name": name,
                "level": level
            ]
            NotificationCenter.default.post(
                name: .didUpdateBluetoothBattery,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func stateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .resetting: return "Resetting"
        case .unsupported: return "Unsupported"
        case .unauthorized: return "Unauthorized"
        case .poweredOff: return "Powered Off"
        case .poweredOn: return "Powered On"
        @unknown default: return "Unknown State"
        }
    }

    func requestBatteryUpdate() {
        // 1. Check for any new system-connected devices we missed
        if let central = centralManager, central.state == .poweredOn {
            let systemConnected = central.retrieveConnectedPeripherals(withServices: commonServices)
            for peripheral in systemConnected {
                if shouldTrackDevice(peripheral) && connectedPeripherals[peripheral.identifier] == nil {
                    logger.info("🔄 Found new system-connected peripheral: \(peripheral.name ?? "Unknown")")
                    connectToPeripheral(peripheral)
                }
            }
        }

        // 2. Refresh data for all connected devices
        for peripheral in connectedPeripherals.values {
            if peripheral.state == .connected {
                if let services = peripheral.services {
                    for service in services where service.uuid == batteryServiceUUID {
                        if let characteristics = service.characteristics {
                            for characteristic in characteristics where characteristic.uuid == batteryLevelCharacteristicUUID {
                                peripheral.readValue(for: characteristic)
                            }
                        }
                    }
                }
            } else {
                centralManager.connect(peripheral, options: nil)
            }
        }

    }
}
