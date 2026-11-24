import SwiftUI

@main
struct TinyRefsApp: App {
    var body: some Scene {
        WindowGroup("TinyRefs") {
            ContentUnavailableView("Library", systemImage: "books.vertical")
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}
