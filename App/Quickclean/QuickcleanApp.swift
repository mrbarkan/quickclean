import SwiftUI

@main
struct QuickcleanApp: App {
    @State private var model = ScanModel()

    var body: some Scene {
        Window("Quickclean", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button(model.isScanning ? "Cancel Scan" : "Scan Now") {
                    model.isScanning ? model.cancel() : model.scan()
                }
                .keyboardShortcut("r")
                Divider()
                Button("Export JSON Report…") { model.export(.json) }.disabled(model.findings.isEmpty)
                Button("Export Markdown Summary…") { model.export(.markdown) }.disabled(model.findings.isEmpty)
            }
        }
    }
}
