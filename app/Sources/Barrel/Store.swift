import Foundation
import Observation

struct Bottle: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    var engine: String
    var renderer: String
    var hud: Bool
    var retina: Bool
    var id: String { name }
    var driveC: URL { URL(fileURLWithPath: path).appendingPathComponent("drive_c") }
    var logURL: URL { URL(fileURLWithPath: path).appendingPathComponent("barrel.log") }
}

struct Program: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

private struct CheckOutput: Codable {
    let updates: [String]
}

private struct ListOutput: Codable {
    let engines: [String]
    let runtime: String
    let bottles: [Bottle]
}

/// Talks to the `barrel` command-line tool, which holds all the Wine logic.
@MainActor @Observable
final class Store {
    var bottles: [Bottle] = []
    var engines: [String] = []
    var runtime = ""
    var busy: String?          // what a long task is doing, nil when idle
    var output = ""            // output of the last long task
    var error: String?
    var notice: String?

    var isInstalled: Bool { engines.contains { $0.hasPrefix("barrel-") || $0.hasPrefix("sikarugir-") } && !runtime.isEmpty }

    /// The CLI ships inside the app; during development it sits next to the package.
    let cli: String = Bundle.main.path(forResource: "barrel", ofType: nil)
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../cli/barrel").standardized.path

    func refresh() async {
        let (status, text) = await exec(["list", "--json"], stream: false)
        guard status == 0, let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode(ListOutput.self, from: data) else {
            error = "Couldn't read bottles:\n\(text)"
            return
        }
        engines = list.engines
        runtime = list.runtime
        bottles = list.bottles
    }

    /// Runs a CLI command that takes a while, showing its output; refreshes afterwards.
    @discardableResult
    func task(_ title: String, _ args: [String]) async -> Bool {
        busy = title
        output = ""
        let (status, _) = await exec(args, stream: true)
        busy = nil
        if status != 0 { error = output.isEmpty ? "\(title) failed." : output }
        await refresh()
        return status == 0
    }

    // MARK: Wine updates

    static let autoUpdateKey = "autoUpdate", lastCheckKey = "lastUpdateCheck"

    /// True when the last successful check is more than a day old.
    var updateCheckDue: Bool {
        Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Self.lastCheckKey) > 24 * 3600
    }

    /// Looks for newer Wine and graphics builds and installs them. Automatic checks stay quiet,
    /// and wait while a Windows program is running so its engine isn't replaced under it.
    func checkForUpdates(automatic: Bool) async {
        guard isInstalled, busy == nil else { return }
        let (status, text) = await exec(["check", "--json"], stream: false)
        guard status == 0, let data = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(CheckOutput.self, from: data) else {
            if !automatic { error = "Couldn't check for updates:\n\(text)" }
            return
        }
        if result.updates.isEmpty {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            if !automatic { notice = "Wine and the graphics libraries are up to date." }
            return
        }
        if wineIsRunning() {
            if !automatic { error = "Quit your Windows programs first, then update.\n\n" + result.updates.joined(separator: "\n") }
            return
        }
        if await task("Updating " + result.updates.joined(separator: ", "), ["update"]) {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        }
    }

    private func wineIsRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "wineserver"]
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func set(_ bottle: Bottle, _ key: String, _ value: String) async {
        let (status, text) = await exec(["set", bottle.name, key, value], stream: false)
        if status != 0 { error = text }
        await refresh()
    }

    /// Starts a program in the background; its output goes to the bottle's log.
    func launch(_ bottle: Bottle, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [cli] + args
        FileManager.default.createFile(atPath: bottle.logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: bottle.logURL) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }
        do { try p.run() } catch { self.error = error.localizedDescription }
    }

    func run(_ bottle: Bottle, _ file: URL) { launch(bottle, ["run", bottle.name, file.path]) }

    /// Start Menu shortcuts installed in the bottle.
    func programs(_ bottle: Bottle) -> [Program] {
        let fm = FileManager.default
        var roots = [bottle.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        let users = bottle.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            roots.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
        }
        var found: [Program] = []
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "lnk" {
                let name = url.lastPathComponent.lowercased()
                if name.contains("uninstall") || name.contains("wine") { continue }
                found.append(Program(url: url))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func exec(_ args: [String], stream: Bool) async -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [cli] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let collected = Collector()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            collected.add(chunk)
            if stream, let text = String(data: chunk, encoding: .utf8) {
                Task { @MainActor in self?.append(text) }
            }
        }
        let status: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.add(pipe.fileHandleForReading.readDataToEndOfFile())
        return (status, collected.text)
    }

    /// curl redraws its progress bar with \r; keep only the latest version of each line.
    private func append(_ text: String) {
        for ch in text {
            if ch == "\r" {
                if let nl = output.lastIndex(of: "\n") { output = String(output[...nl]) } else { output = "" }
            } else {
                output.append(ch)
            }
        }
    }
}

/// Output gathered from a pipe on a background thread.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
