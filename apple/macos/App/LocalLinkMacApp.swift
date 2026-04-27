import LocalLinkCore
import SwiftUI

@main
struct LocalLinkMacApp: App {
  @State private var model = LocalLinkAppModel()

  var body: some Scene {
    WindowGroup("LocalLink") {
      MacContentView(model: model)
        .frame(minWidth: 860, minHeight: 560)
        .task {
          if !model.isRunning {
            model.start()
          }
        }
    }
    .commands {
      CommandGroup(after: .newItem) {
        Button(model.isRunning ? "Stop LocalLink" : "Start LocalLink") {
          model.isRunning ? model.stop() : model.start()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
    }

    Settings {
      MacSettingsView(model: model)
        .frame(minWidth: 680, idealWidth: 720, minHeight: 520, idealHeight: 560)
    }
  }
}
