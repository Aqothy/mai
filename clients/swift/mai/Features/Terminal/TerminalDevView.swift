import SwiftUI

/// Gate for the development-only live terminal entry point, mirroring
/// ChatPerformanceLab: always on in Debug, opt-in by launch argument
/// elsewhere. Terminal threads become a real product surface in a later
/// increment.
nonisolated enum TerminalLab {
    static let launchArgument = "-TerminalLab"

    static let isEnabled: Bool = {
        #if DEBUG
            true
        #else
            ProcessInfo.processInfo.arguments.contains(launchArgument)
        #endif
    }()
}

/// Development-only live terminal: one daemon shell over the real RPC
/// transport, created with the surface's measured grid.
struct TerminalDevView: View {
    @State private var store = TerminalStore()

    var body: some View {
        TerminalThreadView(controller: store.controller, title: "Terminal (Dev)")
            .overlay(alignment: .center) {
                TerminalPhaseOverlay(phase: store.phase)
            }
            .toolbar {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Terminate", systemImage: "stop.circle", role: .destructive) {
                        store.terminate()
                    }
                    .disabled(store.phase != .running)
                }
            }
            .task {
                store.start()
            }
            .onDisappear {
                store.stop()
            }
    }
}

/// Connection/lifecycle overlay with narrow inputs so phase changes never
/// rebuild the terminal surface.
struct TerminalPhaseOverlay: View {
    let phase: TerminalStore.Phase

    var body: some View {
        switch phase {
        case .idle, .connecting:
            ProgressView("Connecting…")
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .disconnected:
            Label("Disconnected from maiD", systemImage: "wifi.slash")
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .running, .exited:
            EmptyView()
        }
    }
}
