#if !LOCAL_LINK_SINGLE_TARGET
import LocalLinkCore
#endif
import SwiftUI

struct PeerRow: View {
  let peer: DiscoveredPeer

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: iconName(for: peer.identity.platform))
        .foregroundStyle(.secondary)
        .frame(width: 18)
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

struct TransferRow: View {
  let transfer: TransferItem

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(transfer.fileName, systemImage: transfer.direction == .incoming ? "tray.and.arrow.down" : "tray.and.arrow.up")
        Spacer()
        Text(transfer.status.rawValue)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ProgressView(value: transfer.progress)
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
