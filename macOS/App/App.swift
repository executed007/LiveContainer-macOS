import SwiftUI

// LiveContainer for macOS: the app. A library of installed iOS apps, each with its data
// containers and settings, plus the tweaks loaded into them. See Model.swift for the state,
// and macOS/Sources for the shared code the lcmac command-line tool uses as well.

@main
struct LiveContainerApp: App {
    var body: some Scene {
        Window("LiveContainer", id: "main") { RootView() }
            .defaultSize(width: 980, height: 660)
            .windowToolbarStyle(.unified)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
