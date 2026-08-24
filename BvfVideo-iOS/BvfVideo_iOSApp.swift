import SwiftUI
import BvfAppKit

@main
struct BvfVideo_iOSApp: App {
    @State private var cloudManager = iCloudManager("BvfVideo", container: "iCloud.io.bvf.shared")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(cloudManager)
                .task {
                    await cloudManager.initialize()
                    StagingManager.recoverOrphanedFiles(to: cloudManager.appFolderURL)
                }
        }
    }
}
