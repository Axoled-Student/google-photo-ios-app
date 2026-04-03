import SwiftUI

@main
struct GooglePhotoSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .task {
                    await model.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    model.handleScenePhaseChange(newPhase)
                }
        }
    }
}
