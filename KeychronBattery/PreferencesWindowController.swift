import Cocoa

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    private let publisher: HomeAssistantPublisher
    private let discovery = MQTTBrokerDiscovery()

    private let brokerPopup   = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "↻", target: nil, action: nil)
    private let hostField     = NSTextField()
    private let portField     = NSTextField()
    private let userField     = NSTextField()
    private let passField     = NSSecureTextField()
    private let tlsCheckbox   = NSButton(checkboxWithTitle: "Use TLS (suggests port 8883)", target: nil, action: nil)
    private let testButton    = NSButton(title: "Test Connection", target: nil, action: nil)
    private let saveButton    = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton  = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel   = NSTextField(labelWithString: "")

    private static let manualTitle = "Manual entry"

    init(publisher: HomeAssistantPublisher) {
        self.publisher = publisher

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Home Assistant Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(brokersChanged),
                                               name: .mqttBrokersChanged,
                                               object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        discovery.stop()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        hostField.placeholderString = "homeassistant.local"
        portField.placeholderString = "1883"
        userField.placeholderString = "mac-battery"
        passField.placeholderString = "••••••••"

        brokerPopup.target = self
        brokerPopup.action = #selector(brokerSelected)
        rebuildBrokerMenu()

        refreshButton.target = self
        refreshButton.action = #selector(refreshDiscovery)
        refreshButton.bezelStyle = .roundRect
        refreshButton.toolTip = "Re-scan for MQTT brokers"

        tlsCheckbox.target = self
        tlsCheckbox.action = #selector(tlsToggled)

        testButton.target = self
        testButton.action = #selector(testTapped)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 440

        let discoveryRow = NSStackView(views: [brokerPopup, refreshButton])
        discoveryRow.orientation = .horizontal
        discoveryRow.spacing = 6

        let form = NSGridView(views: [
            [label("Discovered:"), discoveryRow],
            [label("Host:"),       hostField],
            [label("Port:"),       portField],
            [label("Username:"),   userField],
            [label("Password:"),   passField],
            [NSView(),             tlsCheckbox]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 8
        form.columnSpacing = 8
        for row in 0..<form.numberOfRows {
            form.row(at: row).height = 24
        }
        form.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [testButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [form, statusLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            brokerPopup.widthAnchor.constraint(equalToConstant: 280),
            refreshButton.widthAnchor.constraint(equalToConstant: 30),
            hostField.widthAnchor.constraint(equalToConstant: 320),
            portField.widthAnchor.constraint(equalToConstant: 100),
            userField.widthAnchor.constraint(equalToConstant: 320),
            passField.widthAnchor.constraint(equalToConstant: 320)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    // MARK: - Broker menu

    private func rebuildBrokerMenu() {
        brokerPopup.removeAllItems()

        let brokers = discovery.brokers
        if brokers.isEmpty {
            brokerPopup.addItem(withTitle: "Searching…")
            brokerPopup.item(at: 0)?.isEnabled = false
        } else {
            for broker in brokers {
                brokerPopup.addItem(withTitle: broker.displayName)
                brokerPopup.lastItem?.representedObject = broker
            }
        }

        brokerPopup.menu?.addItem(.separator())
        let manual = NSMenuItem(title: Self.manualTitle, action: nil, keyEquivalent: "")
        brokerPopup.menu?.addItem(manual)
        brokerPopup.selectItem(withTitle: Self.manualTitle)
    }

    @objc private func brokersChanged() {
        rebuildBrokerMenu()
    }

    // MARK: - Load / Save

    private func loadValues() {
        let d = UserDefaults.standard
        hostField.stringValue = d.string(forKey: HomeAssistantPublisher.hostKey) ?? ""
        let port = d.integer(forKey: HomeAssistantPublisher.portKey)
        portField.stringValue = port > 0 ? String(port) : "1883"
        let user = d.string(forKey: HomeAssistantPublisher.usernameKey) ?? ""
        userField.stringValue = user
        passField.stringValue = user.isEmpty ? "" : (KeychronCredentials.password(account: user) ?? "")
        tlsCheckbox.state = d.bool(forKey: HomeAssistantPublisher.useTLSKey) ? .on : .off
    }

    private func currentValues() -> (host: String, port: UInt16, user: String, pass: String, useTLS: Bool)? {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let pass = passField.stringValue
        let portInt = Int(portField.stringValue) ?? 1883
        let port = UInt16(max(1, min(65535, portInt)))
        let useTLS = tlsCheckbox.state == .on

        guard !host.isEmpty, !user.isEmpty, !pass.isEmpty else {
            showStatus("Host, username and password are required.", isError: true)
            return nil
        }
        return (host, port, user, pass, useTLS)
    }

    // MARK: - Actions

    @objc private func brokerSelected() {
        guard let selected = brokerPopup.selectedItem,
              let broker = selected.representedObject as? MQTTBrokerDiscovery.Broker else { return }

        showStatus("Resolving \(broker.serviceName)…", isError: false)
        discovery.resolve(broker) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let (host, port)):
                self.hostField.stringValue = host
                self.portField.stringValue = String(port)
                if broker.kind != .homeAssistant {
                    self.tlsCheckbox.state = broker.suggestsTLS ? .on : .off
                }
                self.showStatus("✓ Picked \(broker.serviceName) at \(host):\(port)", isError: false)
            case .failure(let err):
                self.showStatus("✗ Resolve failed: \(err.localizedDescription)", isError: true)
                self.brokerPopup.selectItem(withTitle: Self.manualTitle)
            }
        }
    }

    @objc private func refreshDiscovery() {
        discovery.stop()
        rebuildBrokerMenu()
        discovery.start()
    }

    @objc private func tlsToggled() {
        let useTLS = tlsCheckbox.state == .on
        let cur = portField.stringValue
        if useTLS && (cur.isEmpty || cur == "1883") {
            portField.stringValue = "8883"
        } else if !useTLS && cur == "8883" {
            portField.stringValue = "1883"
        }
    }

    @objc private func testTapped() {
        guard let v = currentValues() else { return }
        testButton.isEnabled = false
        saveButton.isEnabled = false
        showStatus("Testing connection…", isError: false)

        HomeAssistantPublisher.testConnection(host: v.host, port: v.port,
                                              username: v.user, password: v.pass,
                                              useTLS: v.useTLS) { [weak self] result in
            guard let self = self else { return }
            self.testButton.isEnabled = true
            self.saveButton.isEnabled = true
            switch result {
            case .success:
                self.showStatus("✓ Connected successfully.", isError: false)
            case .failure(let err):
                self.showStatus("✗ \(err.localizedDescription)", isError: true)
            }
        }
    }

    @objc private func saveTapped() {
        guard let v = currentValues() else { return }

        let d = UserDefaults.standard
        let previousUser = d.string(forKey: HomeAssistantPublisher.usernameKey)
        if let prev = previousUser, prev != v.user {
            KeychronCredentials.deletePassword(account: prev)
        }
        d.set(v.host, forKey: HomeAssistantPublisher.hostKey)
        d.set(Int(v.port), forKey: HomeAssistantPublisher.portKey)
        d.set(v.user, forKey: HomeAssistantPublisher.usernameKey)
        d.set(v.useTLS, forKey: HomeAssistantPublisher.useTLSKey)
        KeychronCredentials.setPassword(v.pass, account: v.user)

        publisher.reconfigure()
        close()
    }

    @objc private func cancelTapped() {
        close()
    }

    // MARK: - Status

    private func showStatus(_ msg: String, isError: Bool) {
        statusLabel.stringValue = msg
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Show / Close

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        discovery.start()
    }

    func windowWillClose(_ notification: Notification) {
        discovery.stop()
    }
}
