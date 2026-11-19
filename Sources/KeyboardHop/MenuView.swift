import SwiftUI

struct MenuView: View {
    @EnvironmentObject var hop: HopController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("KeyboardHop").font(.headline)

            if hop.devices.isEmpty {
                Text("No paired Bluetooth devices found. Pair a device in System Settings > Bluetooth first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if !hop.hasEnabledDevices {
                    Text("Switch on the devices you want KeyboardHop to reconnect automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(hop.devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.name).lineLimit(1)
                            Text(device.connected ? "Connected" : "Not connected")
                                .font(.caption2)
                                .foregroundStyle(device.connected ? .green : .secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { device.enabled },
                                                 set: { hop.setEnabled($0, for: device.id) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            }

            Divider()

            Toggle("Pause auto-connect", isOn: $hop.paused)
            Toggle("Launch at login", isOn: Binding(get: { hop.launchAtLogin },
                                                    set: { hop.setLaunchAtLogin($0) }))
            Toggle("Show Dock icon", isOn: Binding(get: { hop.showDockIcon },
                                                   set: { hop.setShowDockIcon($0) }))
            HStack {
                Button("Connect now") { hop.reconnectNow() }.disabled(!hop.hasEnabledDevices)
                Button("Refresh") { hop.refreshDevices() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { hop.refreshDevices() }
    }
}
