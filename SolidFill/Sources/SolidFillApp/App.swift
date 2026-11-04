import SwiftUI

@main
struct SolidFillApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("SolidFill") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
                .onOpenURL { model.load(url: $0) }
        }
        .windowResizability(.contentMinSize)
    }
}
