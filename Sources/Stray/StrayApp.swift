import SwiftUI

@main
struct StrayApp: App {
    @StateObject private var engine = Engine()

    init() {
        // Tryb CLI: `Stray --scan` robi jeden przebieg i kończy, bez GUI.
        if CommandLine.arguments.contains("--scan") {
            CLI.scan()
            exit(0)
        }
        Notifier.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: engine)
                .onAppear { engine.start() }
        } label: {
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        if engine.criticalCount > 0 { return "figure.walk.motion" }
        if engine.warningCount > 0 { return "figure.walk" }
        return "figure.walk.departure"
    }
}
