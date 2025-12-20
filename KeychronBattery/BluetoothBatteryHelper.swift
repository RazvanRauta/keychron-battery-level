import Foundation
import CoreBluetooth
import os

extension Notification.Name {
    static let didUpdateBluetoothBattery = Notification.Name("didUpdateBluetoothBattery")
}

class BluetoothBatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.keychron.battery", category: "BluetoothMonitor")
    private var centralManager: CBCentralManager!
    private var keychronPeripheral: CBPeripheral?
    private var batteryLevel: Int = -1

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

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
            logger.info("🔍 Scanning for Keychron devices...")
            // Scan for peripherals with battery service
            centralManager.scanForPeripherals(withServices: [batteryServiceUUID], options: nil)

            // Also check already connected peripherals
            let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
            for peripheral in connectedPeripherals {
                logger.info("📱 Found connected peripheral: \(peripheral.name ?? "Unknown")")
                if isKeychronDevice(peripheral) {
                    connectToPeripheral(peripheral)
                }
            }
        } else {
            logger.warning("⚠️ Bluetooth not available")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"

        if isKeychronDevice(peripheral) {
            logger.info("✅ Found Keychron: \(name)")
            centralManager.stopScan()
            connectToPeripheral(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("🔗 Connected to \(peripheral.name ?? "device")")
        peripheral.delegate = self
        logger.info("🔍 Discovering services...")
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("❌ Disconnected from \(peripheral.name ?? "device")")
        batteryLevel = -1
        notifyBatteryUpdate()

        // Try to reconnect
        if let keychron = keychronPeripheral {
            centralManager.connect(keychron, options: nil)
        }
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
                batteryLevel = Int(level)
                logger.info("🔋 Battery Level: \(self.batteryLevel)%")
                notifyBatteryUpdate()
            }
        }
    }

    // MARK: - Helper Methods

    private func isKeychronDevice(_ peripheral: CBPeripheral) -> Bool {
        let name = peripheral.name?.lowercased() ?? ""
        return name.contains("keychron") || name.contains("k2")
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        keychronPeripheral = peripheral
        centralManager.connect(peripheral, options: nil)
    }

    private func notifyBatteryUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .didUpdateBluetoothBattery,
                object: self.batteryLevel
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
        guard let peripheral = keychronPeripheral, peripheral.state == .connected else {
            logger.warning("⚠️ Keyboard not connected. Attempting to reconnect...")

            guard let central = centralManager, central.state == .poweredOn else {
                logger.warning("⚠️ Bluetooth manager not ready")
                return
            }

            let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])

            for peripheral in connectedPeripherals where isKeychronDevice(peripheral) {
                logger.info("🔄 Found connected peripheral during refresh: \(peripheral.name ?? "Unknown")")
                connectToPeripheral(peripheral)
                return
            }

            if !central.isScanning {
                logger.info("🔍 Restarting scan...")
                central.scanForPeripherals(withServices: [batteryServiceUUID], options: nil)
            }
            return
        }

        if let services = peripheral.services {
            for service in services where service.uuid == batteryServiceUUID {
                if let characteristics = service.characteristics {
                    for characteristic in characteristics where characteristic.uuid == batteryLevelCharacteristicUUID {
                        peripheral.readValue(for: characteristic)
                        return
                    }
                }
            }
        }

        peripheral.discoverServices([batteryServiceUUID])
    }
}
