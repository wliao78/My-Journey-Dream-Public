import SwiftUI

@main
struct MyJourneyDreamApp: App {
    @State private var store = DreamStore()

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if let preview = PublicLocalizationQA.screen { preview } else { DreamHomeView(store: store) }
#else
                DreamHomeView(store: store)
#endif
            }.environment(\.locale, PublicLanguage.locale)
                .preferredColorScheme(.dark)
        }
    }
}
