import SwiftUI
import UniformTypeIdentifiers

private let renderers: [(id: String, name: String, help: String)] = [
    ("d3dmetal", "D3DMetal", "Apple's DirectX 11/12 layer. Best for most modern games (64-bit only; 32-bit games use DXMT)."),
    ("dxmt", "DXMT", "DirectX 10/11 to Metal. Try it when a game fails with D3DMetal."),
    ("dxvk", "DXVK", "DirectX 9-11 over Vulkan and MoltenVK."),
    ("wined3d", "WineD3D", "Wine's own OpenGL renderer, for old games."),
]

private let runnable: [UTType] = ["exe", "msi", "bat", "lnk"].compactMap { UTType(filenameExtension: $0) }

struct BottleView: View {
    @Environment(Store.self) private var store
    let bottle: Bottle
    @State private var programs: [Program] = []
    @State private var confirmDelete = false
    @State private var dropTargeted = false

    var body: some View {
        Form {
            Section {
                if programs.isEmpty {
                    Text("Nothing installed yet. Run an installer, or drop a .exe here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(programs) { program in
                    HStack {
                        Label(program.name, systemImage: "app")
                        Spacer()
                        Button("Run") { store.run(bottle, program.url) }
                    }
                    .contextMenu {
                        Button("Add to Applications") {
                            Task { await store.task("Adding \(program.name)", ["app", bottle.name, program.url.path, program.name]) }
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([program.url]) }
                    }
                }
            } header: {
                HStack {
                    Text("Programs")
                    Spacer()
                    Button("Run…", action: pickAndRun)
                }
            }

            Section("Graphics") {
                Picker("Renderer", selection: binding(\.renderer, "renderer") { $0 }) {
                    ForEach(renderers, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(bottle.engine == "staging")
                Text(renderers.first { $0.id == bottle.renderer }?.help ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Performance HUD", isOn: binding(\.hud, "hud") { $0 ? "on" : "off" })
                Toggle("Retina resolution", isOn: binding(\.retina, "retina") { $0 ? "on" : "off" })
            }

            Section("Bottle") {
                LabeledContent("Engine", value: ["barrel": "Barrel Wine (CrossOver)", "sikarugir": "Wine (Sikarugir)",
                                                 "staging": "Wine Staging (upstream)"][bottle.engine] ?? bottle.engine)
                HStack {
                    Button("Open C: Drive") { NSWorkspace.shared.open(bottle.driveC) }
                    Button("Wine Configuration") { store.launch(bottle, ["cfg", bottle.name]) }
                    Button("Show Log") { NSWorkspace.shared.open(bottle.logURL) }
                        .disabled(!FileManager.default.fileExists(atPath: bottle.logURL.path))
                    Spacer()
                    Button("Stop All") { store.launch(bottle, ["kill", bottle.name]) }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(6)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.run(bottle, url) }
                }
            }
            return true
        }
        .task(id: bottle) { programs = store.programs(bottle) }
        // Installers add Start Menu entries while they run; check again when the app comes back to front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            programs = store.programs(bottle)
        }
        .confirmationDialog("Delete \(bottle.name)?", isPresented: $confirmDelete) {
            Button("Delete Bottle", role: .destructive) {
                Task { await store.task("Deleting \(bottle.name)", ["rm", bottle.name, "--yes"]) }
            }
        } message: {
            Text("Everything installed in this bottle will be removed.")
        }
    }

    private func pickAndRun() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = runnable
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { store.run(bottle, url) }
    }

    /// A binding that shows the bottle's value and saves changes through the CLI.
    private func binding<T>(_ key: KeyPath<Bottle, T>, _ name: String, _ value: @escaping (T) -> String) -> Binding<T> {
        Binding(
            get: { bottle[keyPath: key] },
            set: { new in Task { await store.set(bottle, name, value(new)) } }
        )
    }
}
