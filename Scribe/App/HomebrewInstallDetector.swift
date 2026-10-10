import Foundation

/// How a Homebrew cask install relates to in-app (Sparkle) updates.
enum ScribeHomebrewUpdatePolicy: Equatable, Sendable {
    /// Not installed through Homebrew (DMG/zip download, dev build, …).
    case notHomebrew
    /// Installed by the cask, and the cask declares `auto_updates true`, so
    /// Homebrew expects the app to update itself (Sparkle stays on).
    case homebrewAllowsAppUpdates
    /// Installed by a cask that does NOT declare `auto_updates true`: the user
    /// upgrades with `brew upgrade`, so the in-app updater stays out of the way.
    case managedByHomebrew
}

/// Detects whether this copy of Scribe was installed by the `scribe` Homebrew
/// cask, and whether that cask lets the app update itself.
///
/// Homebrew moves the app into `/Applications` (or `~/Applications`) and keeps
/// the cask's metadata under `<prefix>/Caskroom/scribe/.metadata/<version>/
/// <timestamp>/Casks/scribe.{rb,json}`. The decision itself is pure (see
/// `policy(…)`); `detect()` only gathers the inputs from disk.
enum ScribeHomebrewInstallDetector {

    nonisolated static let caskToken = "scribe"
    nonisolated static let appBundleName = "Scribe.app"
    /// Apple Silicon prefix first; the Intel prefix is kept for Rosetta-era
    /// Homebrew installs that were migrated.
    nonisolated static let defaultCaskroomRoots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

    // MARK: - Pure helpers

    /// Normalizes a filesystem path for prefix comparisons (no trailing slash).
    nonisolated static func normalized(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// True when `appPath` lives inside one of `caskroomRoots`.
    nonisolated static func isInsideCaskroom(appPath: String, caskroomRoots: [String]) -> Bool {
        let app = normalized(appPath)
        return caskroomRoots.contains { root in
            let prefix = normalized(root) + "/"
            return app.hasPrefix(prefix)
        }
    }

    /// True when `appPath` is where a cask's `app` stanza installs Scribe:
    /// `/Applications/Scribe.app` or `~/Applications/Scribe.app`.
    nonisolated static func isCaskAppLocation(appPath: String, homeDirectory: String) -> Bool {
        let app = normalized(appPath)
        let candidates = [
            "/Applications/" + appBundleName,
            normalized(homeDirectory) + "/Applications/" + appBundleName,
        ]
        return candidates.contains(app)
    }

    /// Whether a cask definition declares `auto_updates true`. Accepts the
    /// Ruby source (`scribe.rb`) or Homebrew's JSON form (`scribe.json`).
    nonisolated static func caskDeclaresAutoUpdates(_ caskSource: String) -> Bool {
        // JSON metadata: "auto_updates": true (whitespace-insensitive).
        let compact = caskSource.filter { !$0.isWhitespace }
        if compact.contains("\"auto_updates\":true") { return true }

        // Ruby DSL: a line `auto_updates true`, ignoring comments.
        for rawLine in caskSource.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = line[line.startIndex..<hash]
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            if tokens.count == 2 && tokens[0] == "auto_updates" && tokens[1] == "true" {
                return true
            }
        }
        return false
    }

    /// Picks the newest cask metadata file from paths relative to
    /// `Caskroom/scribe/.metadata` (`<version>/<timestamp>/Casks/scribe.rb`).
    /// Newest = greatest `<timestamp>` component (Homebrew writes sortable
    /// `YYYYMMDDhhmmss.mmm` stamps); on a tie the JSON form wins.
    nonisolated static func latestMetadataCaskFile(_ relativePaths: [String]) -> String? {
        let accepted = Set([caskToken + ".rb", caskToken + ".json"])
        let candidates = relativePaths.filter { path in
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 4, let last = parts.last else { return false }
            return accepted.contains(last) && parts[parts.count - 2] == "Casks"
        }
        func timestamp(_ path: String) -> String {
            let parts = path.split(separator: "/").map(String.init)
            return parts.count >= 4 ? parts[parts.count - 3] : ""
        }
        return candidates.max { lhs, rhs in
            let lt = timestamp(lhs), rt = timestamp(rhs)
            if lt != rt { return lt < rt }
            // Same install: prefer .json, then the lexicographically larger path.
            let lj = lhs.hasSuffix(".json"), rj = rhs.hasSuffix(".json")
            if lj != rj { return !lj && rj }
            return lhs < rhs
        }
    }

    /// The decision. `installedCaskDirectory` is `Caskroom/scribe` when it
    /// exists; `caskSource` is the newest metadata cask file's contents.
    nonisolated static func policy(
        appPath: String,
        homeDirectory: String,
        caskroomRoots: [String],
        installedCaskDirectory: String?,
        caskSource: String?
    ) -> ScribeHomebrewUpdatePolicy {
        let inside = isInsideCaskroom(appPath: appPath, caskroomRoots: caskroomRoots)
        let caskManagedLocation = installedCaskDirectory != nil
            && isCaskAppLocation(appPath: appPath, homeDirectory: homeDirectory)
        guard inside || caskManagedLocation else { return .notHomebrew }
        if let caskSource, caskDeclaresAutoUpdates(caskSource) {
            return .homebrewAllowsAppUpdates
        }
        return .managedByHomebrew
    }

    // MARK: - Disk

    /// Gathers the inputs for `policy(…)` from disk. Cheap (a couple of stat
    /// calls plus a walk of the tiny `.metadata` folder); safe off-main.
    nonisolated static func detect() -> ScribeHomebrewUpdatePolicy {
        let fileManager = FileManager.default
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = fileManager.homeDirectoryForCurrentUser.path
        let roots = defaultCaskroomRoots

        var caskDirectory: String?
        for root in roots {
            let candidate = normalized(root) + "/" + caskToken
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                caskDirectory = candidate
                break
            }
        }
        // Inside-a-Caskroom installs (`--appdir` into the Caskroom) have their
        // own metadata next to them.
        if caskDirectory == nil, isInsideCaskroom(appPath: appPath, caskroomRoots: roots) {
            for root in roots where appPath.hasPrefix(normalized(root) + "/") {
                caskDirectory = normalized(root) + "/" + caskToken
            }
        }

        var caskSource: String?
        if let caskDirectory {
            let metadata = caskDirectory + "/.metadata"
            var relativePaths: [String] = []
            if let enumerator = fileManager.enumerator(atPath: metadata) {
                while let next = enumerator.nextObject() as? String {
                    relativePaths.append(next)
                    if relativePaths.count > 500 { break } // defensive bound
                }
            }
            if let latest = latestMetadataCaskFile(relativePaths) {
                caskSource = try? String(contentsOfFile: metadata + "/" + latest, encoding: .utf8)
            }
        }

        return policy(
            appPath: appPath,
            homeDirectory: home,
            caskroomRoots: roots,
            installedCaskDirectory: caskDirectory,
            caskSource: caskSource
        )
    }
}
