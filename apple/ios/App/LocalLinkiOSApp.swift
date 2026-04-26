#if !LOCAL_LINK_SINGLE_TARGET
import LocalLinkCore
#endif
import SwiftUI

@main
struct LocalLinkiOSApp: App {
  @State private var model = LocalLinkAppModel()

  var body: some Scene {
    WindowGroup {
      IOSContentView(model: model)
        .task {
          if !model.isRunning {
            model.start()
          }
        }
    }
  }
}
