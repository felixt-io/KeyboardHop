import Foundation
import IOBluetooth
import AppKit
import ServiceManagement

struct HopDevice: Identifiable, Hashable {
    let id: String          // Bluetooth address, e.g. "aa-bb-cc-dd-ee-ff"
    let name: String
    var connected: Bool
    var enabled: Bool

    var symbol: String {
        let n = name.lowercased()
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("mouse") || n.contains("mx ") || n.contains("m585") { return "computermouse" }
        if n.contains("airpods") || n.contains("headphone") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Watches the user's chosen Bluetooth devices and reconnects them as soon as they are available.
final class HopController: NSObject, ObservableObject {
    static let shared = HopController()

    @Published private(set) var devices: [HopDevice] = []
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: Keys.paused); if !paused { reconnectNow() } } }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var showDockIcon: Bool

    var anyEnabledConnected: Bool { devices.contains { $0.enabled && $0.connected } }
    var hasEnabledDevices: Bool { devices.contains { $0.enabled } }
    var hasSavedDevices: Bool { !enabledAddresses.isEmpty }

    private enum Keys {
        static let enabled = "enabledAddresses"
        static let paused = "paused"
        static let firstRunDone = "firstRunDone"
        static let dockIcon = "showDockIcon"
    }

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "keyboardhop.bluetooth")
    private let lock = NSLock()
    private var _enabledAddresses: Set<String>
    /// Read from the Bluetooth queue and written on the main thread, so access is locked.
    private var enabledAddresses: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _enabledAddresses }
        set { lock.lock(); defer { lock.unlock() }; _enabledAddresses = newValue }
    }
    private var inFlight = Set<String>()          // touched only on `queue`
    private var timer: DispatchSourceTimer?
    private var systemAsleep = false
    private var activity: NSObjectProtocol?       // keeps macOS App Nap from delaying the 0.5s timer
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]

    private override init() {
        _enabledAddresses = Set(UserDefaults.standard.stringArray(forKey: Keys.enabled) ?? [])
        paused = UserDefaults.standard.bool(forKey: Keys.paused)
        showDockIcon = UserDefaults.standard.object(forKey: Keys.dockIcon) as? Bool ?? true   // Dock icon on by default
        super.init()
        start()
    }

    // MARK: - Setup

    private func start() {
        if !defaults.bool(forKey: Keys.firstRunDone) {
            defaults.set(true, forKey: Keys.firstRunDone)
            try? SMAppService.mainApp.register()      // launch at login is on by default
        }
        refreshLoginState()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
            reason: "Reconnect Bluetooth devices promptly")

        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:fromDevice:)))

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        refreshDevices()
        startTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.pollTick() }
        t.resume()
        timer = t
    }

    // MARK: - Public actions

    func setEnabled(_ enabled: Bool, for address: String) {
        if enabled { enabledAddresses.insert(address) } else { enabledAddresses.remove(address) }
        defaults.set(Array(enabledAddresses), forKey: Keys.enabled)
        refreshDevices()
        if enabled { connect(address) }
    }

    func reconnectNow() {
        for address in enabledAddresses { connect(address) }
    }

    func setShowDockIcon(_ on: Bool) {
        defaults.set(on, forKey: Keys.dockIcon)
        showDockIcon = on
        applyDockPolicy()
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("KeyboardHop: login item change failed: \(error.localizedDescription)")
        }
        refreshLoginState()
    }

    func refreshDevices() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let list = paired.compactMap { d -> HopDevice? in
            guard let address = d.addressString else { return nil }
            return HopDevice(id: address,
                             name: d.nameOrAddress ?? address,
                             connected: d.isConnected(),
                             enabled: enabledAddresses.contains(address))
        }
        .sorted { ($0.enabled ? 0 : 1, $0.name) < ($1.enabled ? 0 : 1, $1.name) }

        for d in paired {
            guard let address = d.addressString else { continue }
            if enabledAddresses.contains(address), disconnectNotes[address] == nil {
                disconnectNotes[address] = d.register(forDisconnectNotification: self,
                                                      selector: #selector(deviceDisconnected(_:fromDevice:)))
            } else if !enabledAddresses.contains(address), let note = disconnectNotes.removeValue(forKey: address) {
                note.unregister()
            }
        }

        DispatchQueue.main.async { self.devices = list }
    }

    private func refreshLoginState() {
        let on = SMAppService.mainApp.status == .enabled
        DispatchQueue.main.async { self.launchAtLogin = on }
    }

    // MARK: - Connecting

    private func pollTick() {
        guard !paused, !systemAsleep else { return }
        for address in enabledAddresses { connectIfNeeded(address) }
    }

    private func connect(_ address: String) {
        queue.async { [weak self] in self?.connectIfNeeded(address) }
    }

    /// Must run on `queue`. Skips if already connected or an attempt is in flight.
    private func connectIfNeeded(_ address: String) {
        guard !paused, !inFlight.contains(address),
              let device = IOBluetoothDevice(addressString: address),
              device.isPaired(), !device.isConnected() else { return }
        inFlight.insert(address)
        _ = device.openConnection()                   // blocks until it succeeds or times out
        inFlight.remove(address)
        DispatchQueue.main.async { self.refreshDevices() }
    }

    // MARK: - Notifications

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        DispatchQueue.main.async { self.refreshDevices() }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        DispatchQueue.main.async { self.refreshDevices() }
        guard let address = device.addressString else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.systemAsleep else { return }
            self.connectIfNeeded(address)
        }
    }

    @objc private func willSleep() { systemAsleep = true }

    @objc private func didWake() {
        systemAsleep = false
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            for address in self.enabledAddresses { self.connectIfNeeded(address) }
        }
    }
}
