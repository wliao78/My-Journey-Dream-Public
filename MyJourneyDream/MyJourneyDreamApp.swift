import SwiftUI

@main
struct MyJourneyDreamApp: App {
    @State private var store = DreamStore()

    var body: some Scene {
        WindowGroup {
            DreamHomeView(store: store)
                .preferredColorScheme(.dark)
        }
    }
}
