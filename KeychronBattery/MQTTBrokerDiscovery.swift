import Foundation
import Network
import os

extension Notification.Name {
    static let mqttBrokersChanged = Notification.Name("mqttBrokersChanged")
}

final class MQTTBrokerDiscovery {

    enum Kind {
        case mqtt          // _mqtt._tcp
        case mqttSecure    // _secure-mqtt._tcp
        case homeAssistant // _home-assistant._tcp — port heuristically assumed to be 1883

        init?(serviceType: String) {
            switch serviceType {
            case "_mqtt._tcp":           self = .mqtt
            case "_secure-mqtt._tcp":    self = .mqttSecure
            case "_home-assistant._tcp": self = .homeAssistant
            default: return nil
            }
        }
    }

    struct Broker: Hashable {
        let kind: Kind
        let serviceName: String
        let serviceType: String
        let endpoint: NWEndpoint
        let txt: [String: String]

        var displayName: String {
            switch kind {
            case .mqtt:          return "\(serviceName) (mqtt)"
            case .mqttSecure:    return "\(serviceName) (mqtts)"
            case .homeAssistant: return "\(serviceName) — Home Assistant (probable MQTT)"
            }
        }

        var suggestsTLS: Bool { kind == .mqttSecure }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.rrazvan.keychron.battery",
                                category: "Discovery")

    private(set) var brokers: [Broker] = [] {
        didSet {
            guard brokers != oldValue else { return }
            NotificationCenter.default.post(name: .mqttBrokersChanged, object: self)
        }
    }

    private var browsers: [NWBrowser] = []
    private let serviceTypes = ["_mqtt._tcp", "_secure-mqtt._tcp", "_home-assistant._tcp"]

    func start() {
        guard browsers.isEmpty else { return }

        for type in serviceTypes {
            let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: nil)
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: descriptor, using: parameters)

            browser.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.logger.error("Browser \(type) failed: \(error.localizedDescription)")
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handleResults(results, serviceType: type)
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        logger.info("Started Bonjour discovery")
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        brokers = []
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, serviceType: String) {
        guard let kind = Kind(serviceType: serviceType) else { return }

        let updated = results.compactMap { result -> Broker? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            return Broker(kind: kind,
                          serviceName: name,
                          serviceType: serviceType,
                          endpoint: result.endpoint,
                          txt: Self.extractTXT(result.metadata))
        }

        var combined = brokers.filter { $0.serviceType != serviceType }
        combined.append(contentsOf: updated)
        brokers = combined.sorted { ($0.kind.sortRank, $0.displayName.lowercased())
                                  < ($1.kind.sortRank, $1.displayName.lowercased()) }
        logger.info("Discovered \(self.brokers.count) broker candidate(s)")
    }

    private static func extractTXT(_ metadata: NWBrowser.Result.Metadata) -> [String: String] {
        if case let .bonjour(record) = metadata {
            return record.dictionary
        }
        return [:]
    }

    // MARK: - Resolution

    func resolve(_ broker: Broker,
                 timeout: TimeInterval = 5.0,
                 completion: @escaping (Result<(host: String, port: UInt16), Error>) -> Void) {

        // 1. For HA: prefer the hostname from the `base_url` TXT record if present.
        if broker.kind == .homeAssistant,
           let baseURL = broker.txt["base_url"] ?? broker.txt["internal_url"],
           let url = URL(string: baseURL),
           let host = url.host, !host.isEmpty {
            DispatchQueue.main.async {
                completion(.success((host, 1883)))
            }
            return
        }

        // 2. Otherwise resolve via NWConnection, forcing IPv4 so we don't end up
        //    with an unreachable-after-roam link-local IPv6 like fe80::…%en0.
        let parameters = NWParameters.tcp
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        parameters.includePeerToPeer = false

        let connection = NWConnection(to: broker.endpoint, using: parameters)
        var didFinish = false
        let queue = DispatchQueue.main

        func finish(_ result: Result<(host: String, port: UInt16), Error>) {
            if didFinish { return }
            didFinish = true
            connection.cancel()
            queue.async { completion(result) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   case let .hostPort(host, port) = path.remoteEndpoint {
                    let hostString = Self.hostString(host)
                    let resolvedPort: UInt16 = (broker.kind == .homeAssistant) ? 1883 : port.rawValue
                    finish(.success((hostString, resolvedPort)))
                } else {
                    finish(.failure(NSError(domain: "Discovery", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "Could not resolve service endpoint"])))
                }
            case .failed(let err):
                finish(.failure(err))
            default:
                break
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(NSError(domain: "Discovery", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Resolve timed out"])))
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let addr):
            // Strip the %interface suffix some IPv4 addresses include
            let s = "\(addr)"
            return s.split(separator: "%").first.map(String.init) ?? s
        case .ipv6(let addr):    return "\(addr)"
        @unknown default:        return ""
        }
    }
}

private extension MQTTBrokerDiscovery.Kind {
    var sortRank: Int {
        switch self {
        case .mqtt:          return 0
        case .mqttSecure:    return 1
        case .homeAssistant: return 2
        }
    }
}

private extension NWTXTRecord {
    var dictionary: [String: String] {
        var result: [String: String] = [:]
        for (key, entry) in self {
            if case let .string(value) = entry {
                result[key] = value
            }
        }
        return result
    }
}
