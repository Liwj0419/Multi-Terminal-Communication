import AppKit
import LocalLinkCore
import SwiftUI
import UniformTypeIdentifiers

private enum MacPeerPanel: String, CaseIterable, Identifiable {
  case messages = "Messages"
  case pictures = "Pictures"
  case files = "Files"

  var id: String { rawValue }
}

struct MacContentView: View {
  @Bindable var model: LocalLinkAppModel

  private var selectedPeer: DiscoveredPeer? {
    guard let selectedPeerID = model.selectedPeerID else { return nil }
    return model.peer(forPeerID: selectedPeerID)
  }

  var body: some View {
    NavigationSplitView {
      MacSidebarView(model: model)
    } detail: {
      if let selectedPeer {
        MacPeerDetailView(model: model, peer: selectedPeer)
      } else {
        ContentUnavailableView("Select a Device", systemImage: "dot.radiowaves.left.and.right")
      }
    }
    .sheet(item: $model.pairingPrompt) { prompt in
      PairingSheet(model: model, prompt: prompt)
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

struct MacSidebarView: View {
  @Bindable var model: LocalLinkAppModel

  var body: some View {
    List(selection: $model.selectedPeerID) {
      Section("Nearby") {
        if model.discoveredPeers.isEmpty {
          Label("Searching", systemImage: "magnifyingglass")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.discoveredPeers) { peer in
            PeerRow(peer: peer)
              .tag(peer.id)
          }
        }
      }

      Section("Trusted") {
        if model.trustedPeers.isEmpty {
          Text("No paired devices")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.trustedPeers) { peer in
            VStack(alignment: .leading, spacing: 2) {
              Label(peer.displayName, systemImage: iconName(for: peer.platform))
              if let host = peer.lastHost, let port = peer.lastPort {
                Text("\(host):\(port)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .tag(peer.id)
            .contextMenu {
              Button("Forget Device", role: .destructive) {
                model.forget(peerID: peer.deviceID)
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("LocalLink")
    .toolbar {
      ToolbarItem {
        SettingsLink {
          Image(systemName: "gearshape")
        }
        .help("Settings")
      }
      ToolbarItem {
        Button {
          model.isRunning ? model.stop() : model.start()
        } label: {
          Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
        }
        .help(model.isRunning ? "Stop discovery" : "Start discovery")
      }
    }
  }
}

struct MacPeerDetailView: View {
  @Bindable var model: LocalLinkAppModel
  let peer: DiscoveredPeer

  @State private var text = ""
  @State private var isImportingFile = false
  @State private var selectedPanel: MacPeerPanel = .messages

  private var peerMessages: [ConversationMessage] {
    model.messages.filter { $0.peerID == currentPeer.identity.deviceID }
  }

  private var peerPictures: [TransferItem] {
    model.transfers.filter { $0.peerID == currentPeer.identity.deviceID && $0.isPicture }
  }

  private var peerFiles: [TransferItem] {
    model.transfers.filter { $0.peerID == currentPeer.identity.deviceID && !$0.isPicture }
  }

  private var currentPeer: DiscoveredPeer {
    model.resolvedPeer(peer)
  }

  private var isConnected: Bool {
    model.isConnected(peerID: currentPeer.identity.deviceID)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      panelPicker
      detailPanel
      Divider()
      composer
    }
    .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.item]) { result in
      if case let .success(url) = result {
        model.sendFile(url, to: currentPeer)
      }
    }
  }

  private var header: some View {
    HStack {
      Label(currentPeer.identity.displayName, systemImage: iconName(for: currentPeer.identity.platform))
        .font(.title3)
      Spacer()
      if currentPeer.isTrusted {
        Label(isConnected ? "Connected" : "Paired", systemImage: isConnected ? "bolt.horizontal.circle.fill" : "checkmark.seal.fill")
          .foregroundStyle(.green)
        if isConnected {
          Button("Disconnect") {
            model.disconnect(peerID: currentPeer.identity.deviceID)
          }
        } else {
          Button("Connect") {
            model.connect(to: currentPeer)
          }
          .disabled(currentPeer.endpoint == nil)
        }
      } else {
        Button("Pair") {
          model.pair(with: currentPeer)
        }
      }
    }
    .padding()
  }

  private var panelPicker: some View {
    Picker("Content", selection: $selectedPanel) {
      ForEach(MacPeerPanel.allCases) { panel in
        Text(panel.rawValue).tag(panel)
      }
    }
    .pickerStyle(.segmented)
    .padding([.horizontal, .top])
  }

  @ViewBuilder
  private var detailPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        switch selectedPanel {
        case .messages:
          if peerMessages.isEmpty {
            ContentUnavailableView("No Messages", systemImage: "message")
          } else {
            ForEach(peerMessages) { message in
              MessageBubble(message: message)
            }
          }
        case .pictures:
          if peerPictures.isEmpty {
            ContentUnavailableView("No Pictures", systemImage: "photo")
          } else {
            ForEach(peerPictures) { transfer in
              TransferRow(
                transfer: transfer,
                onDownload: { download(transfer) },
                onOpen: { open(transfer) },
                onReveal: { reveal(transfer) }
              )
            }
          }
        case .files:
          if peerFiles.isEmpty {
            ContentUnavailableView("No Files", systemImage: "doc")
          } else {
            ForEach(peerFiles) { transfer in
              TransferRow(
                transfer: transfer,
                onDownload: { download(transfer) },
                onOpen: nil,
                onReveal: { reveal(transfer) }
              )
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
  }

  private var composer: some View {
    HStack(spacing: 10) {
      Button {
        isImportingFile = true
      } label: {
        Image(systemName: "paperclip")
      }
      .disabled(!isConnected)
      .help("Send file")

      TextField("Send text", text: $text)
        .textFieldStyle(.roundedBorder)
        .onSubmit(sendText)
        .disabled(!isConnected)

      Button(action: sendText) {
        Image(systemName: "paperplane.fill")
      }
      .disabled(!isConnected)
      .keyboardShortcut(.return, modifiers: [.command])
      .help("Send text")
    }
    .padding()
  }

  private func sendText() {
    model.sendText(text, to: currentPeer)
    text = ""
  }

  private func download(_ transfer: TransferItem) {
    do {
      let url = try model.downloadTransfer(transfer)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      model.lastErrorMessage = error.localizedDescription
    }
  }

  private func open(_ transfer: TransferItem) {
    guard let data = model.transferData(for: transfer) else {
      model.lastErrorMessage = "The picture is not available locally."
      return
    }
    do {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalLinkPreview", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("\(transfer.id.uuidString)-\(transfer.fileName)")
      try data.write(to: url, options: [.atomic])
      NSWorkspace.shared.open(url)
    } catch {
      model.lastErrorMessage = error.localizedDescription
    }
  }

  private func reveal(_ transfer: TransferItem) {
    guard let url = model.localFileURL(for: transfer) else {
      model.lastErrorMessage = "Download this file before opening its folder."
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

struct PairingSheet: View {
  @Bindable var model: LocalLinkAppModel
  let prompt: PairingPrompt
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "link.badge.plus")
        .font(.system(size: 42))
        .foregroundStyle(.tint)

      Text(prompt.identity.displayName)
        .font(.title2)

      Text(prompt.code)
        .font(.system(size: 42, weight: .semibold, design: .rounded))
        .monospacedDigit()

      HStack {
        Button("Cancel", role: .cancel) {
          model.pairingPrompt = nil
          dismiss()
        }
        Button("Confirm Pairing") {
          model.confirmPairing(with: prompt.identity)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(28)
  }
}

struct MessageBubble: View {
  let message: ConversationMessage

  var body: some View {
    HStack {
      if message.isOutgoing { Spacer() }
      Text(message.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(message.isOutgoing ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      if !message.isOutgoing { Spacer() }
    }
  }
}

struct TransferRow: View {
  let transfer: TransferItem
  var onDownload: (() -> Void)?
  var onOpen: (() -> Void)?
  var onReveal: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(transfer.fileName, systemImage: transfer.direction == .incoming ? "tray.and.arrow.down" : "tray.and.arrow.up")
        Spacer()
        if let onOpen {
          Button("View", action: onOpen)
        }
        if let onDownload {
          Button("Download", action: onDownload)
        }
        if let onReveal {
          Button("Show", action: onReveal)
        }
        Text(transfer.status.rawValue)
          .foregroundStyle(.secondary)
      }
      ProgressView(value: transfer.progress)
    }
    .padding(12)
    .background(.quaternary.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

struct PeerRow: View {
  let peer: DiscoveredPeer

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: iconName(for: peer.identity.platform))
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(peer.identity.displayName)
          .lineLimit(1)
        Text(peer.isTrusted ? "Paired" : peer.endpointDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

func iconName(for platform: DevicePlatform) -> String {
  switch platform {
  case .iOS: "iphone"
  case .macOS: "macbook"
  case .android: "smartphone"
  case .windows: "desktopcomputer"
  case .unknown: "questionmark.circle"
  }
}
