import LocalLinkCore
import SwiftUI

struct MacSettingsView: View {
  @Bindable var model: LocalLinkAppModel
  @State private var deviceName = ""

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
}
