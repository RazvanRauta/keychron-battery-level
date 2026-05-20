import Foundation
import IOKit
import CocoaMQTT
import os

extension Notification.Name {
    static let haPublisherStatusChanged = Notification.Name("haPublisherStatusChanged")
}

final class HomeAssistantPublisher: NSObject, CocoaMQTTDelegate {

    enum Status: Equatable {
        case notConfigured
        case connecting
        case connected
        case error(String)

        var displayString: String {
            switch self {
            case .notConfigured: return "Home Assistant: not configured"
            case .connecting:    return "Home Assistant: connecting…"
            case .connected:     return "Home Assistant: connected"
            case .error(let m):  return "Home Assistant: \(m)"
            }
        }
    }

    static let discoveryPrefix = "homeassistant"
    static let topicPrefix = "keychron_battery"

    static let hostKey      = "ha.mqtt.host"
    static let portKey      = "ha.mqtt.port"
    static let usernameKey  = "ha.mqtt.username"
    static let useTLSKey    = "ha.mqtt.useTLS"

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.rrazvan.keychron.battery", category: "HAPublisher")

    private(set) var status: Status = .notConfigured {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: .haPublisherStatusChanged, object: self)
        }
    }

    private var mqtt: CocoaMQTT?
    private var publishedDiscoveryFor = Set<String>()
    private var bridgeDiscoveryPublished = false
    private var pendingStates: [String: (name: String, level: Int)] = [:]

    private let bridgeId: String
    private let bridgeName: String
    private var availabilityTopic: String { "\(Self.topicPrefix)/bridge/availability" }

    override init() {
        self.bridgeId = "\(Self.topicPrefix)_bridge_\(Self.macHardwareUUID().replacingOccurrences(of: "-", with: "").lowercased())"
        self.bridgeName = Host.current().localizedName ?? "Mac"
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveBluetoothBattery(_:)),
                                               name: .didUpdateBluetoothBattery, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveHIDBattery(_:)),
                                               name: .didReceiveBatteryLevel, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Lifecycle

    func start() {
        let d = UserDefaults.standard
        guard let host = d.string(forKey: Self.hostKey), !host.isEmpty,
              let username = d.string(forKey: Self.usernameKey), !username.isEmpty,
              let password = KeychronCredentials.password(account: username), !password.isEmpty else {
            status = .notConfigured
            logger.info("HA publisher: no config — skipping")
            return
        }

        let storedPort = d.integer(forKey: Self.portKey)
        let port = UInt16(storedPort > 0 ? storedPort : 1883)
        let useTLS = d.bool(forKey: Self.useTLSKey)

        connect(host: host, port: port, username: username, password: password, useTLS: useTLS)
    }

    func stop() {
        mqtt?.disconnect()
        mqtt = nil
        publishedDiscoveryFor.removeAll()
        bridgeDiscoveryPublished = false
        status = .notConfigured
    }

    func reconfigure() {
        stop()
        start()
    }

    private func connect(host: String, port: UInt16, username: String, password: String, useTLS: Bool) {
        let clientID = "keychron-battery-\(ProcessInfo.processInfo.hostName)-\(getpid())"
        let client = CocoaMQTT(clientID: clientID, host: host, port: port)
        client.username = username
        client.password = password
        client.keepAlive = 60
        client.cleanSession = true
        client.autoReconnect = true
        client.autoReconnectTimeInterval = 5
        client.enableSSL = useTLS
        client.willMessage = CocoaMQTTMessage(topic: availabilityTopic, string: "offline", qos: .qos1, retained: true)
        client.delegate = self
        self.mqtt = client
        status = .connecting
        _ = client.connect()
    }

    // MARK: - Observers

    @objc private func didReceiveBluetoothBattery(_ notification: Notification) {
        guard let info = notification.userInfo,
              let uuid  = info["uuid"]  as? String,
              let name  = info["name"]  as? String,
              let level = info["level"] as? Int else { return }
        publish(uuid: uuid, name: name, level: level)
    }

    @objc private func didReceiveHIDBattery(_ notification: Notification) {
        guard let level = notification.object as? Int else { return }
        publish(uuid: "HID-DEVICE-001", name: "Wired/HID Device", level: level)
    }

    private func publish(uuid: String, name: String, level: Int) {
        let slug = slugify(uuid)
        pendingStates[slug] = (name: name, level: level)

        guard let client = mqtt, client.connState == .connected else { return }
        publishDiscoveryIfNeeded(slug: slug, name: name)
        publishState(slug: slug, level: level)
    }

    // MARK: - Discovery / state

    private func publishDiscoveryIfNeeded(slug: String, name: String) {
        if publishedDiscoveryFor.contains(slug) { return }
        guard let client = mqtt else { return }

        let uniqueId = "\(Self.topicPrefix)_\(slug)"
        let payload: [String: Any] = [
            "name": "Battery",
            "unique_id": uniqueId,
            "state_topic": "\(Self.topicPrefix)/\(slug)/state",
            "availability_topic": availabilityTopic,
            "device_class": "battery",
            "unit_of_measurement": "%",
            "state_class": "measurement",
            "device": [
                "identifiers": [uniqueId],
                "name": name,
                "via_device": bridgeId
            ]
        ]

        guard let json = jsonString(payload) else { return }
        _ = client.publish("\(Self.discoveryPrefix)/sensor/\(uniqueId)/config",
                           withString: json, qos: .qos1, retained: true)
        publishedDiscoveryFor.insert(slug)
        logger.info("Published discovery for \(name)")
    }

    private func publishBridgeDiscovery() {
        guard !bridgeDiscoveryPublished, let client = mqtt else { return }

        let payload: [String: Any] = [
            "name": "Bridge",
            "unique_id": "\(bridgeId)_status",
            "state_topic": availabilityTopic,
            "payload_on": "online",
            "payload_off": "offline",
            "device_class": "connectivity",
            "entity_category": "diagnostic",
            "device": [
                "identifiers": [bridgeId],
                "name": "\(bridgeName) (Keychron Battery)",
                "manufacturer": "Apple",
                "model": "Mac"
            ]
        ]

        guard let json = jsonString(payload) else { return }
        _ = client.publish("\(Self.discoveryPrefix)/binary_sensor/\(bridgeId)_status/config",
                           withString: json, qos: .qos1, retained: true)
        bridgeDiscoveryPublished = true
    }

    private func publishState(slug: String, level: Int) {
        guard let client = mqtt else { return }
        let value = level >= 0 ? String(level) : ""
        _ = client.publish("\(Self.topicPrefix)/\(slug)/state",
                           withString: value, qos: .qos1, retained: true)
    }

    private func flushPending() {
        for (slug, info) in pendingStates {
            publishDiscoveryIfNeeded(slug: slug, name: info.name)
            publishState(slug: slug, level: info.level)
        }
    }

    // MARK: - Helpers

    private func slugify(_ uuid: String) -> String {
        uuid.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func jsonString(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func macHardwareUUID() -> String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if entry != 0 { IOObjectRelease(entry) } }
        guard entry != 0,
              let raw = IORegistryEntryCreateCFProperty(entry, kIOPlatformUUIDKey as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        else { return "unknown" }
        return raw
    }

    // MARK: - CocoaMQTTDelegate

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .accept {
            logger.info("MQTT connected")
            status = .connected
            _ = mqtt.publish(availabilityTopic, withString: "online", qos: .qos1, retained: true)
            publishBridgeDiscovery()
            flushPending()
        } else {
            logger.error("MQTT refused: \(String(describing: ack))")
            status = .error("Refused: \(ack)")
        }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        if let err = err {
            logger.info("MQTT disconnected: \(err.localizedDescription)")
            status = .error(err.localizedDescription)
        } else {
            logger.info("MQTT disconnected cleanly")
            status = .notConfigured
        }
        publishedDiscoveryFor.removeAll()
        bridgeDiscoveryPublished = false
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}

// MARK: - One-shot connection test (used by Preferences "Test Connection")

extension HomeAssistantPublisher {
    static func testConnection(host: String, port: UInt16,
                               username: String, password: String,
                               useTLS: Bool,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        let probe = ConnectionProbe(completion: completion)
        probe.run(host: host, port: port, username: username, password: password, useTLS: useTLS)
    }
}

private final class ConnectionProbe: NSObject, CocoaMQTTDelegate {
    private var client: CocoaMQTT?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var selfRef: ConnectionProbe?
    private var timeoutTimer: Timer?

    init(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        super.init()
        self.selfRef = self
    }

    func run(host: String, port: UInt16, username: String, password: String, useTLS: Bool) {
        let clientID = "keychron-battery-test-\(UUID().uuidString.prefix(8))"
        let c = CocoaMQTT(clientID: clientID, host: host, port: port)
        c.username = username
        c.password = password
        c.keepAlive = 30
        c.cleanSession = true
        c.autoReconnect = false
        c.enableSSL = useTLS
        c.delegate = self
        self.client = c
        _ = c.connect()

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.finish(.failure(NSError(domain: "HAPublisher", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "Connection timed out"])))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let cb = completion else { return }
        completion = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        client?.disconnect()
        DispatchQueue.main.async {
            cb(result)
            self.selfRef = nil
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .accept {
            finish(.success(()))
        } else {
            finish(.failure(NSError(domain: "HAPublisher", code: Int(ack.rawValue),
                                    userInfo: [NSLocalizedDescriptionKey: "Connection refused: \(ack)"])))
        }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        if let err = err { finish(.failure(err)) }
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
