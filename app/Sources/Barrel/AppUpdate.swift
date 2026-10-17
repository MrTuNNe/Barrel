import AppKit
import Foundation

/// A Barrel release on GitHub (tags like v0.2.0; Wine builds use wine-cx-* tags and are ignored).
struct AppRelease: Equatable {
    let version: String
    let url: URL
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
}

/// "v1.10.2" -> [1, 10, 2]; nil when it isn't a plain version tag.
func versionParts(_ tag: String) -> [Int]? {
    let parts = (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag).split(separator: ".")
    let numbers = parts.compactMap { Int($0) }
    return numbers.count == parts.count && !numbers.isEmpty ? numbers : nil
}

func isNewer(_ a: [Int], than b: [Int]) -> Bool {
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

extension Store {
    static let skippedVersionKey = "skippedAppVersion", lastAppCheckKey = "lastAppUpdateCheck"

    var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    var appCheckDue: Bool {
        Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Self.lastAppCheckKey) > 24 * 3600
    }

    /// Looks for a newer Barrel release on GitHub and offers it. Automatic checks stay quiet
    /// when there's nothing new, on errors, and for a version the user chose to skip.
    func checkForAppUpdate(manual: Bool) async {
        guard let current = currentVersion, let currentParts = versionParts(current) else {
            if manual { notice = "This is a development build, so it can't check for updates." }
            return
        }
        let api = URL(string: "https://api.github.com/repos/MrTuNNe/Barrel/releases?per_page=100")!
        guard let (data, _) = try? await URLSession.shared.data(from: api),
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            if manual { error = "Couldn't reach GitHub to check for updates." }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAppCheckKey)

        let newest = releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { r in versionParts(r.tag_name).map { (parts: $0, release: r) } }
            .max { isNewer($1.parts, than: $0.parts) }
        guard let newest, isNewer(newest.parts, than: currentParts) else {
            if manual { notice = "Barrel \(current) is the newest version." }
            return
        }
        let version = newest.parts.map(String.init).joined(separator: ".")
        if !manual && UserDefaults.standard.string(forKey: Self.skippedVersionKey) == version { return }
        appUpdate = AppRelease(version: version, url: newest.release.html_url)
    }

    func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
        appUpdate = nil
    }

    func download(_ release: AppRelease) {
        NSWorkspace.shared.open(release.url)
        appUpdate = nil
    }
}
