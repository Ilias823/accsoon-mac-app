import CineEyeProtocol
import SwiftUI

/// Reads the transmitter's Wi-Fi channel and lets the user change it.
/// The name and password are sent back unchanged; they are never shown or stored.
struct TransmitterSettingsView: View {
    let client: StreamClient

    @State private var current: AccessPoint?
    @State private var selectedChannel = 0
    @State private var message = "Not read yet."
    @State private var busy = false
    @State private var confirming = false

    var body: some View {
        Section("Transmitter Wi-Fi (experimental, never tested on a device)") {
            LabeledContent("Network", value: current?.name ?? "—")
            Picker("Channel", selection: $selectedChannel) {
                if !AccessPoint.channels.contains(selectedChannel) {
                    Text(current == nil ? "—" : "\(selectedChannel)").tag(selectedChannel)
                }
                ForEach(AccessPoint.channels, id: \.self) { Text("\($0)").tag($0) }
            }
            .disabled(current == nil || busy)
            HStack {
                Button("Read from Transmitter") { read() }
                    .disabled(busy)
                Button("Change Channel…") { confirming = true }
                    .disabled(busy || !canChange)
                if busy { ProgressView().controlSize(.small) }
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if current == nil { read() } }
        .confirmationDialog("Change the transmitter to channel \(selectedChannel)?", isPresented: $confirming) {
            Button("Change Channel") { change() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transmitter will restart its Wi-Fi. This Mac and every other viewer will be disconnected and must join the network again. The network name and password stay the same.")
        }
    }

    /// Only offer the change when the settings were read and the result would be accepted.
    private var canChange: Bool {
        guard let current, selectedChannel != current.channel else { return false }
        return AccessPoint(name: current.name, password: current.password, channel: selectedChannel).isValid
    }

    private func canSendUnchanged(_ ap: AccessPoint) -> Bool {
        AccessPoint(name: ap.name, password: ap.password, channel: AccessPoint.channels[0]).isValid
    }

    private func read() {
        busy = true
        client.readAccessPoint { result in
            busy = false
            switch result {
            case .success(let ap):
                current = ap
                selectedChannel = ap.channel
                if canSendUnchanged(ap) {
                    message = AccessPoint.channels.contains(ap.channel)
                        ? "On channel \(ap.channel)."
                        : "On channel \(ap.channel), which is not one of the selectable channels."
                } else {
                    message = "On channel \(ap.channel). The channel cannot be changed from here: this transmitter's name or password is in a form the change command does not accept."
                }
            case .failure(let error):
                message = Self.describe(error)
            }
        }
    }

    private func change() {
        guard let current else { return }
        busy = true
        let wanted = AccessPoint(name: current.name, password: current.password, channel: selectedChannel)
        client.writeAccessPoint(wanted) { result in
            busy = false
            switch result {
            case .success(let ap):
                self.current = ap
                selectedChannel = ap.channel
                message = ap.channel == wanted.channel
                    ? "The transmitter accepted channel \(ap.channel). Join its Wi-Fi again if this Mac dropped off."
                    : "The transmitter answered but still reports channel \(ap.channel)."
            case .failure(.noAnswer):
                message = "No answer after sending the change. The transmitter may be restarting its Wi-Fi: join its network again, then press Read."
            case .failure(let error):
                selectedChannel = current.channel
                message = Self.describe(error)
            }
        }
    }

    private static func describe(_ error: StreamClient.SettingsError) -> String {
        switch error {
        case .notConnected: "Not connected to the transmitter. Join its Wi-Fi first."
        case .noAnswer: "The transmitter did not answer."
        case .unexpectedAnswer: "The transmitter answered in a form this app does not understand. Nothing was changed."
        case .refused: "These settings are not in a form the transmitter accepts. Nothing was sent."
        }
    }
}
