import SwiftUI
import UniformTypeIdentifiers

/// Receives the .exe/.msi/.bat/.lnk files opened with Barrel from Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            Store.shared.openedFiles += urls
            Store.shared.runOpenedFiles()
        }
    }
}

@main
struct BarrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store.shared
    @AppStorage(Store.autoUpdateKey) private var autoUpdate = true

    var body: some Scene {
        // A single window: opening files from Finder shouldn't open another one each time.
        Window("Barrel", id: "main") {
            ContentView()
                .environment(store)
                .task {
                    await store.refresh()
                    store.runOpenedFiles()
                    // Check once a day, the first time right after launch.
                    while !Task.isCancelled {
                        if store.appCheckDue { await store.checkForAppUpdate(manual: false) }
                        if autoUpdate && store.updateCheckDue { await store.checkForUpdates(automatic: true) }
                        try? await Task.sleep(for: .seconds(3600))
                    }
                }
        }
        .defaultSize(width: 860, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Barrel Updates…") { Task { await store.checkForAppUpdate(manual: true) } }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage(Store.autoUpdateKey) private var autoUpdate = true
    @State private var defaultMessage = ""

    var body: some View {
        Form {
            Toggle("Update Wine automatically", isOn: $autoUpdate)
            Text("Barrel checks once a day and installs new versions of Wine and the graphics libraries when no Windows program is running.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Windows programs") {
                Button("Open .exe, .msi, .bat and .lnk with Barrel") { makeDefault() }
            }
            Text(defaultMessage.isEmpty ? "Double-clicking a Windows program in Finder will then run it in Barrel." : defaultMessage)
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private func makeDefault() {
        let types = ["com.microsoft.windows-executable", "com.microsoft.msi-installer", "com.microsoft.bat",
                     "com.microsoft.windows-shortcut", "com.microsoft.windows-cmd"].compactMap { UTType($0) }
        Task {
            var failed = 0
            for type in types {
                do { try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) }
                catch { failed += 1 }
            }
            defaultMessage = failed == 0 ? "Done. Windows programs now open with Barrel."
                : "macOS didn't allow changing \(failed) of them. Use Finder: Get Info › Open with › Barrel › Change All."
        }
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
        .sheet(isPresented: .constant(store.isInstalled && store.busy == nil && store.bottles.count != 1
                                      && !store.openedFiles.isEmpty)) {
            OpenFileSheet { name in selection = name }
        }
        .onChange(of: store.isInstalled) { store.runOpenedFiles() }
        .onChange(of: store.busy) { store.runOpenedFiles() }
        .alert("Something went wrong", isPresented: .constant(store.error != nil)) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .alert(store.notice ?? "", isPresented: .constant(store.notice != nil)) {
            Button("OK") { store.notice = nil }
        }
        .alert("Barrel \(store.appUpdate?.version ?? "") is available", isPresented: .constant(store.appUpdate != nil)) {
            if let release = store.appUpdate {
                Button("Download") { store.download(release) }
                Button("Skip This Version") { store.skip(release) }
                Button("Later", role: .cancel) { store.appUpdate = nil }
            }
        } message: {
            Text("You have version \(store.currentVersion ?? "?"). Download the new one from GitHub?")
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

/// Asks which bottle a file opened from Finder should run in (the last used one is preselected),
/// or creates the first bottle when there are none.
struct OpenFileSheet: View {
    @Environment(Store.self) private var store
    @State private var bottleName = ""
    @State private var newName = "Games"
    let ran: (String) -> Void

    private var file: URL? { store.openedFiles.first }
    private var newNameValid: Bool {
        let n = newName.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !n.contains("/") && !n.hasPrefix(".")
    }

    var body: some View {
        Form {
            Section("Run \u{201C}\(file?.lastPathComponent ?? "")\u{201D} in") {
                if store.bottles.isEmpty {
                    TextField("New bottle", text: $newName)
                } else {
                    Picker("Bottle", selection: $bottleName) {
                        ForEach(store.bottles) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { bottleName = store.defaultBottle?.name ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { store.openedFiles.removeFirst() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Run") { runIt() }
                    .disabled(store.bottles.isEmpty ? !newNameValid : bottleName.isEmpty)
            }
        }
    }

    private func runIt() {
        guard let file else { return }
        store.openedFiles.removeFirst()
        if let bottle = store.bottles.first(where: { $0.name == bottleName }) {
            store.run(bottle, file)
            ran(bottle.name)
            return
        }
        let name = newName.trimmingCharacters(in: .whitespaces)
        Task {
            guard await store.task("Creating bottle \(name)", ["new", name]),
                  let bottle = store.bottles.first(where: { $0.name == name }) else { return }
            store.run(bottle, file)
            ran(name)
        }
    }
}
