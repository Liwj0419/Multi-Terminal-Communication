#if !LOCAL_LINK_SINGLE_TARGET
import LocalLinkCore
#endif
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum IOSPeerPanel: String, CaseIterable, Identifiable {
  case messages = "Messages"
  case pictures = "Pictures"
  case files = "Files"

  var id: String { rawValue }
}

private struct ImagePreviewItem: Identifiable {
  let id = UUID()
  let image: UIImage
}

struct IOSContentView: View {
  @Bindable var model: LocalLinkAppModel

  var body: some View {
    NavigationStack {
      List {
        Section("Nearby") {
          if model.discoveredPeers.isEmpty {
            Label("Searching", systemImage: "magnifyingglass")
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.discoveredPeers) { peer in
              NavigationLink {
                IOSPeerDetailView(model: model, peer: peer)
              } label: {
                PeerRow(peer: peer)
              }
            }
          }
        }

        Section("Trusted") {
          if model.trustedPeers.isEmpty {
            Text("No paired devices")
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.trustedPeers) { peer in
              NavigationLink {
                IOSPeerDetailView(model: model, peer: model.peer(for: peer))
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Label(peer.displayName, systemImage: iconName(for: peer.platform))
                  if let host = peer.lastHost, let port = peer.lastPort {
                    Text("\(host):\(port)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .swipeActions {
                Button("Clear Messages", role: .destructive) {
                  model.clearMessages(peerID: peer.deviceID)
                }
                Button("Forget", role: .destructive) {
                  model.forget(peerID: peer.deviceID)
                }
              }
            }
          }
        }
      }
      .navigationTitle("LocalLink")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            IOSSettingsView(model: model)
          } label: {
            Image(systemName: "gearshape")
          }
        }
        ToolbarItem(placement: .topBarLeading) {
          Button {
            model.isRunning ? model.stop() : model.start()
          } label: {
            Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
          }
          .accessibilityLabel(model.isRunning ? "Stop discovery and disconnect" : "Start discovery and accept connections")
        }
      }
    }
    .sheet(item: $model.pairingPrompt) { prompt in
      IOSPairingSheet(model: model, prompt: prompt)
    }
    .alert("LocalLink", isPresented: Binding(
      get: { model.lastErrorMessage != nil },
      set: { if !$0 { model.lastErrorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.lastErrorMessage ?? "")
    }
  }
}

struct IOSPeerDetailView: View {
  @Bindable var model: LocalLinkAppModel
  let peer: DiscoveredPeer

  @State private var text = ""
  @State private var isImportingFile = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var selectedPanel: IOSPeerPanel = .messages
  @State private var previewItem: ImagePreviewItem?

  private var currentPeer: DiscoveredPeer {
    model.resolvedPeer(peer)
  }

  private var isConnected: Bool {
    model.isConnected(peerID: currentPeer.identity.deviceID)
  }

  private var peerMessages: [ConversationMessage] {
    model.messages.filter { $0.peerID == currentPeer.identity.deviceID }
  }

  private var peerPictures: [TransferItem] {
    model.transfers.filter { $0.peerID == currentPeer.identity.deviceID && $0.isPicture }
  }

  private var peerFiles: [TransferItem] {
    model.transfers.filter { $0.peerID == currentPeer.identity.deviceID && !$0.isPicture }
  }

  var body: some View {
    VStack(spacing: 0) {
      List {
        Section {
          HStack {
            Label(currentPeer.identity.displayName, systemImage: iconName(for: currentPeer.identity.platform))
            Spacer()
            if currentPeer.isTrusted {
              Label(isConnected ? "Connected" : "Paired", systemImage: isConnected ? "bolt.horizontal.circle.fill" : "checkmark.seal.fill")
                .foregroundStyle(.green)
            } else {
              Button("Pair") {
                model.pair(with: currentPeer)
              }
              .buttonStyle(.borderedProminent)
            }
          }

          if currentPeer.isTrusted {
            if isConnected {
              Button("Disconnect", role: .destructive) {
                model.disconnect(peerID: currentPeer.identity.deviceID)
              }
            } else {
              Button("Connect") {
                model.connect(to: currentPeer)
              }
              .disabled(currentPeer.endpoint == nil)
            }
          }
        }

        Section {
          Picker("Content", selection: $selectedPanel) {
            ForEach(IOSPeerPanel.allCases) { panel in
              Text(panel.rawValue).tag(panel)
            }
          }
          .pickerStyle(.segmented)
        }

        detailSection
      }

      HStack(spacing: 10) {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
          Image(systemName: "photo")
        }
        .disabled(!isConnected)

        Button {
          isImportingFile = true
        } label: {
          Image(systemName: "paperclip")
        }
        .disabled(!isConnected)

        TextField("Send text", text: $text)
          .textFieldStyle(.roundedBorder)
          .onSubmit(sendText)
          .disabled(!isConnected)

        Button(action: sendText) {
          Image(systemName: "paperplane.fill")
        }
        .disabled(!isConnected)
      }
      .padding()
      .background(.bar)
    }
    .navigationTitle(currentPeer.identity.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.item]) { result in
      if case let .success(url) = result {
        model.sendFile(url, to: currentPeer)
      }
    }
    .onChange(of: selectedPhotoItem) { _, item in
      guard let item else { return }
      Task {
        await sendPhoto(item)
      }
    }
    .sheet(item: $previewItem) { item in
      NavigationStack {
        Image(uiImage: item.image)
          .resizable()
          .scaledToFit()
          .padding()
          .navigationTitle("Picture")
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }

  @ViewBuilder
  private var detailSection: some View {
    switch selectedPanel {
    case .messages:
      Section("Messages") {
        if peerMessages.isEmpty {
          Text("No messages")
            .foregroundStyle(.secondary)
        } else {
          ForEach(peerMessages) { message in
            Text(message.text)
              .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
              .contextMenu {
                Button("Copy") {
                  UIPasteboard.general.string = message.text
                }
              }
          }
        }
      }
    case .pictures:
      Section("Pictures") {
        if peerPictures.isEmpty {
          Text("No pictures")
            .foregroundStyle(.secondary)
        } else {
          ForEach(peerPictures) { transfer in
            IOSTransferActionRow(
              transfer: transfer,
              viewTitle: "View",
              onView: { preview(transfer) },
              onDownload: { downloadPicture(transfer) }
            )
          }
        }
      }
    case .files:
      Section("Files") {
        if peerFiles.isEmpty {
          Text("No files")
            .foregroundStyle(.secondary)
        } else {
          ForEach(peerFiles) { transfer in
            IOSTransferActionRow(
              transfer: transfer,
              viewTitle: nil,
              onView: nil,
              onDownload: { downloadFile(transfer) }
            )
          }
        }
      }
    }
  }

  private func sendText() {
    model.sendText(text, to: currentPeer)
    text = ""
  }

  private func sendPhoto(_ item: PhotosPickerItem) async {
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else { return }
      let contentType = item.supportedContentTypes.first
      let ext = contentType?.preferredFilenameExtension ?? "jpg"
      let fileName = "Photo-\(Date().timeIntervalSince1970).\(ext)"
      model.sendData(data, fileName: fileName, contentType: contentType?.identifier, to: currentPeer)
      selectedPhotoItem = nil
    } catch {
      model.lastErrorMessage = error.localizedDescription
    }
  }

  private func preview(_ transfer: TransferItem) {
    guard let data = model.transferData(for: transfer), let image = UIImage(data: data) else {
      model.lastErrorMessage = "The picture is not available locally."
      return
    }
    previewItem = ImagePreviewItem(image: image)
  }

  private func downloadPicture(_ transfer: TransferItem) {
    guard let data = model.transferData(for: transfer), let image = UIImage(data: data) else {
      model.lastErrorMessage = "The picture is not available locally."
      return
    }
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    model.lastErrorMessage = "Saved to Photos."
  }

  private func downloadFile(_ transfer: TransferItem) {
    do {
      let url = try model.downloadTransfer(transfer)
      model.lastErrorMessage = "Downloaded to \(url.lastPathComponent)."
    } catch {
      model.lastErrorMessage = error.localizedDescription
    }
  }
}

private struct IOSTransferActionRow: View {
  let transfer: TransferItem
  let viewTitle: String?
  var onView: (() -> Void)?
  var onDownload: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TransferRow(transfer: transfer)
      HStack {
        if let viewTitle, let onView {
          Button(viewTitle, action: onView)
        }
        Button("Download", action: onDownload)
      }
    }
  }
}

struct IOSPairingSheet: View {
  @Bindable var model: LocalLinkAppModel
  let prompt: PairingPrompt
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Image(systemName: "link.badge.plus")
          .font(.system(size: 52))
          .foregroundStyle(.tint)
        Text(prompt.identity.displayName)
          .font(.title2)
        Text(prompt.code)
          .font(.system(size: 46, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Button("Confirm Pairing") {
          model.confirmPairing(with: prompt.identity)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
      .padding()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.pairingPrompt = nil
            dismiss()
          }
        }
      }
    }
  }
}

struct IOSSettingsView: View {
  @Bindable var model: LocalLinkAppModel
  @State private var deviceName = ""
  @State private var manualEndpoint = ""

  var body: some View {
    Form {
      Section("This Device") {
        TextField("Device name", text: $deviceName)
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
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.numbersAndPunctuation)
        Button("Connect Manually") {
          model.connectManually(to: manualEndpoint)
          manualEndpoint = ""
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
    .navigationTitle("Settings")
    .onAppear {
      deviceName = model.localIdentity?.displayName ?? ""
    }
  }
}
