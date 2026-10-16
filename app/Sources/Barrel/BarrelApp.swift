import SwiftUI

@main
struct BarrelApp: App {
    @State private var store = Store()
    @AppStorage(Store.autoUpdateKey) private var autoUpdate = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task {
                    await store.refresh()
                    // Check once a day, the first time right after launch.
                    while !Task.isCancelled {
                        if autoUpdate && store.updateCheckDue { await store.checkForUpdates(automatic: true) }
                        try? await Task.sleep(for: .seconds(3600))
                    }
                }
        }
        .defaultSize(width: 860, height: 560)

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage(Store.autoUpdateKey) private var autoUpdate = true

    var body: some View {
        Form {
            Toggle("Update Wine automatically", isOn: $autoUpdate)
            Text("Barrel checks once a day and installs new versions of Wine and the graphics libraries when no Windows program is running.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var selection: String?
    @State private var creating = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(store.bottles, selection: $selection) { bottle in
                Label(bottle.name, systemImage: "cylinder.split.1x2")
                    .tag(bottle.name)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .toolbar {
                Button { creating = true } label: { Label("New Bottle", systemImage: "plus") }
                    .disabled(!store.isInstalled || store.busy != nil)
            }
        } detail: {
            if store.busy != nil {
                TaskView()
            } else if !store.isInstalled {
                SetupView()
            } else if let bottle = store.bottles.first(where: { $0.name == selection }) {
                BottleView(bottle: bottle)
            } else {
                ContentUnavailableView("No Bottle Selected", systemImage: "cylinder.split.1x2",
                    description: Text("A bottle is a separate Windows install. Create one with +."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.checkForUpdates(automatic: false) }
                } label: { Label("Check for Wine Updates", systemImage: "arrow.down.circle") }
                    .help("Check for and install the newest Wine and graphics libraries")
                    .disabled(!store.isInstalled || store.busy != nil)
            }
        }
        .sheet(isPresented: $creating) {
            NewBottleSheet { name in selection = name }
        }
        .alert("Something went wrong", isPresented: .constant(store.error != nil)) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .alert(store.notice ?? "", isPresented: .constant(store.notice != nil)) {
            Button("OK") { store.notice = nil }
        }
        .onAppear { if selection == nil { selection = store.bottles.first?.name } }
        .onChange(of: store.bottles) { if selection == nil { selection = store.bottles.first?.name } }
    }
}

struct SetupView: View {
    @Environment(Store.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Wine Isn't Installed Yet", systemImage: "wineglass")
        } description: {
            Text("Barrel downloads Wine and the D3DMetal, DXMT and DXVK graphics layers (about 250 MB).")
        } actions: {
            Button("Install") { Task { await store.task("Installing Wine", ["setup"]) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

struct TaskView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(store.busy ?? "").font(.headline)
            }
            ScrollView {
                Text(store.output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
        }
        .padding()
    }
}

struct NewBottleSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let created: (String) -> Void

    private var valid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !n.contains("/") && !n.hasPrefix(".") && !store.bottles.contains { $0.name == n }
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("Games"))
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task {
                        if await store.task("Creating bottle \(n)", ["new", n]) { created(n) }
                    }
                }
                .disabled(!valid)
            }
        }
    }
}
