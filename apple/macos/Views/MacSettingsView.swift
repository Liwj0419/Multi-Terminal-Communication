import LocalLinkCore
import SwiftUI

struct MacSettingsView: View {
  @Bindable var model: LocalLinkAppModel
  @State private var deviceName = ""
  @State private var manualEndpoint = ""

  var body: some View {
    Form {
      Section("This Device") {
        TextField("Device name", text: $deviceName)
          .onSubmit {
            model.updateDeviceName(deviceName)
          }
        Button("Save Name") {
          model.updateDeviceName(deviceName)
        }
      }

      Section("Connection") {
        if model.connectionAddresses.isEmpty {
          Text("Start LocalLink to show this device address.")
            .foregroundStyle(.secondary)
        } else {
          Text(model.connectionAddresses.joined(separator: "\n"))
            .textSelection(.enabled)
        }
        TextField("192.168.1.20:53317", text: $manualEndpoint)
          .onSubmit(connectManually)
        Button("Connect Manually", action: connectManually)
      }

      Section("Trusted Devices") {
        if model.trustedPeers.isEmpty {
          Text("No paired devices")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.trustedPeers) { peer in
            HStack {
              Label(peer.displayName, systemImage: iconName(for: peer.platform))
              Spacer()
              Button("Clear Messages") {
                model.clearMessages(peerID: peer.deviceID)
              }
              Button("Clear Transfers") {
                model.clearTransfers(peerID: peer.deviceID)
              }
              Button("Forget", role: .destructive) {
                model.forget(peerID: peer.deviceID)
              }
            }
          }
        }
      }
    }
    .padding()
    .onAppear {
      deviceName = model.localIdentity?.displayName ?? ""
    }
  }

  private func connectManually() {
    model.connectManually(to: manualEndpoint)
    manualEndpoint = ""
  }
}
