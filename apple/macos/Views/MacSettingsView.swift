import AppKit
import LocalLinkCore
import SwiftUI

struct MacSettingsView: View {
  @Bindable var model: LocalLinkAppModel
  @State private var deviceName = ""
  @State private var manualEndpoint = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        settingsSection("This Device") {
          HStack(spacing: 10) {
            rowLabel("Name")
            TextField("Device name", text: $deviceName)
              .textFieldStyle(.roundedBorder)
              .onSubmit(saveDeviceName)
            Button("Save", action: saveDeviceName)
              .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }

        settingsSection("Connection") {
          HStack(alignment: .top, spacing: 10) {
            rowLabel("This Mac")
            if let address = model.connectionAddresses.first {
              HStack(spacing: 8) {
                Text(address)
                  .font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
                  .lineLimit(1)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                  copy(address)
                } label: {
                  Label("Copy", systemImage: "doc.on.doc")
                }
              }
            } else {
              Text("Start LocalLink to show this device address.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          HStack(spacing: 10) {
            rowLabel("Manual")
            TextField("192.168.1.20:53317", text: $manualEndpoint)
              .textFieldStyle(.roundedBorder)
              .onSubmit(connectManually)
            Button {
              connectManually()
            } label: {
              Label("Connect", systemImage: "link")
            }
            .disabled(manualEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }

        settingsSection("Trusted Devices") {
          if model.trustedPeers.isEmpty {
            HStack(spacing: 10) {
              rowLabel("")
              Text("No paired devices")
                .foregroundStyle(.secondary)
            }
          } else {
            LazyVStack(spacing: 8) {
              ForEach(model.trustedPeers) { peer in
                HStack(spacing: 10) {
                  Label(peer.displayName, systemImage: iconName(for: peer.platform))
                    .lineLimit(1)
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
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
      }
      .padding(24)
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
    .frame(minWidth: 680, minHeight: 520, alignment: .topLeading)
    .onAppear {
      deviceName = model.localIdentity?.displayName ?? ""
    }
  }

  private func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)
      VStack(alignment: .leading, spacing: 10) {
        content()
      }
    }
  }

  private func rowLabel(_ title: String) -> some View {
    Text(title)
      .foregroundStyle(.secondary)
      .frame(width: 86, alignment: .trailing)
  }

  private func saveDeviceName() {
    model.updateDeviceName(deviceName)
  }

  private func connectManually() {
    model.connectManually(to: manualEndpoint)
    manualEndpoint = ""
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
