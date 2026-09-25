import SwiftUI

@main
struct LatchApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(nil)
        }
    }
}
