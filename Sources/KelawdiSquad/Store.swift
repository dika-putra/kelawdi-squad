import AppKit
import CoreServices
import Foundation

struct Profile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
}

// One backup per Claude account (account id = folder name under claude-code-sessions), updated on every profile removal.
struct Backup: Identifiable {
    let url: URL
    let accountID: String
    let profileName: String
    let savedAt: Date
    fileprivate let sourceDir: String
    var id: String { accountID }
}

private struct BackupInfo: Codable {
    var profileName: String
    var savedAt: Date
    var sourceDir: String
}

private struct Config: Codable {
    var defaultName: String
    var profiles: [Profile]
}

private let claudeBundleID = "com.anthropic.claudefordesktop"
private let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

final class Store: ObservableObject {
    static let defaultProfile = Profile(id: "default", name: "Default")

    @Published private(set) var defaultName = "Default"
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var runningPIDs: [String: pid_t] = [:]
    @Published private(set) var update: (version: String, url: URL)?
    private var lastUpdateCheck = Date.distantPast

    private let configDir = appSupport.appendingPathComponent("ClaudeProfileSwitcher")
    private var configFile: URL { configDir.appendingPathComponent("profiles.json") }

    // Demo data for README screenshots (`--screenshot`): never reads or writes the real config.
    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            defaultName = "Personal"
            profiles = [Profile(id: "b2", name: "Work"), Profile(id: "e5", name: "Side project")]
            runningPIDs = ["default": 1, "b2": 2]
        } else {
            load()
            refreshRunning()
        }
    }

    var all: [Profile] { [Profile(id: Store.defaultProfile.id, name: defaultName)] + profiles }

    // Default profile uses Claude's own data dir (no flag), so existing login is kept.
    // Other profiles use Claude-<id>; the id (not the name) names the folder so rename never moves data.
    func dataDir(_ p: Profile) -> URL {
        p.id == Store.defaultProfile.id
            ? appSupport.appendingPathComponent("Claude")
            : appSupport.appendingPathComponent("Claude-\(p.id)")
    }

    // A profile's folder only exists after Claude was launched with it once, so no folder means "not logged in yet".
    func needsLogin(_ p: Profile) -> Bool {
        if demo { return p.id == "e5" }
        return p.id != Store.defaultProfile.id && !FileManager.default.fileExists(atPath: dataDir(p).path)
    }

    func add(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        profiles.append(Profile(id: String(UUID().uuidString.prefix(8)).lowercased(), name: n))
        save()
    }

    func rename(_ p: Profile, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if p.id == Store.defaultProfile.id {
            defaultName = n
        } else if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[i].name = n
        }
        save()
    }

    func remove(_ p: Profile, deleteData: Bool) {
        guard p.id != Store.defaultProfile.id, let i = profiles.firstIndex(of: p) else { return }
        refreshRunning()
        if deleteData, runningPIDs[p.id] == nil {
            let dir = dataDir(p)
            // Only ever delete Claude-<id> directly under Application Support.
            if dir.deletingLastPathComponent().path == appSupport.path, dir.lastPathComponent == "Claude-\(p.id)" {
                // Keep the profile and its data if the backup fails.
                guard backupHistory(of: p) else { return }
                try? FileManager.default.removeItem(at: dir)
            }
        }
        profiles.remove(at: i)
        save()
    }

    // Swaps the data folders of the default profile and p, then swaps their names so each name keeps its account.
    // Three renames with rollback; refuses while any Claude process runs. Returns an error message, or nil on success.
    func makeDefault(_ p: Profile) -> String? {
        refreshRunning()
        guard p.id != Store.defaultProfile.id, let i = profiles.firstIndex(where: { $0.id == p.id }) else {
            return "This profile is already the default."
        }
        guard runningPIDs.isEmpty else { return "Close all Claude windows first." }
        let fm = FileManager.default
        let a = dataDir(Store.defaultProfile)
        let b = dataDir(p)
        let tmp = appSupport.appendingPathComponent("Claude-swap-tmp")
        guard fm.fileExists(atPath: b.path) else { return "Open and log in to this profile once first." }
        guard !fm.fileExists(atPath: tmp.path) else { return "Remove the leftover folder Claude-swap-tmp first." }
        var done: [(from: URL, to: URL)] = []
        do {
            for (from, to) in [(a, tmp), (b, a), (tmp, b)] {
                try fm.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            for step in done.reversed() { try? fm.moveItem(at: step.to, to: step.from) }
            return "Swap failed and was rolled back: \(error.localizedDescription)"
        }
        movePaths(in: a, from: b.path, to: a.path)
        movePaths(in: b, from: a.path, to: b.path)
        let old = defaultName
        defaultName = profiles[i].name
        profiles[i].name = old
        save()
        return nil
    }

    private var backupsDir: URL { configDir.appendingPathComponent("Backups") }

    // Newest first. Folders without info.json (backups from the first version) are ignored.
    func backups() -> [Backup] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        return names.compactMap { name -> Backup? in
            let dir = backupsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")),
                  let info = try? dec.decode(BackupInfo.self, from: data) else { return nil }
            return Backup(url: dir, accountID: name, profileName: info.profileName, savedAt: info.savedAt, sourceDir: info.sourceDir)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    // Merges the backup into the profile's data folder, then rewrites absolute paths that still point at the old
    // profile folder. Returns an error message, or nil.
    func restore(_ b: Backup, to p: Profile) -> String? {
        refreshRunning()
        guard runningPIDs[p.id] == nil else { return "Close this profile's Claude window first." }
        let dest = dataDir(p)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) else { return "Open and log in to this profile once first." }
        do {
            for part in ["claude-code-sessions", "scratch-workspaces"] where fm.fileExists(atPath: b.url.appendingPathComponent(part).path) {
                try copyMerge(b.url.appendingPathComponent(part), into: dest.appendingPathComponent(part))
            }
            let wt = b.url.appendingPathComponent("git-worktrees.json")
            let wtDest = dest.appendingPathComponent("git-worktrees.json")
            if fm.fileExists(atPath: wt.path), !fm.fileExists(atPath: wtDest.path) { try fm.copyItem(at: wt, to: wtDest) }
        } catch {
            return "Restore failed: \(error.localizedDescription)"
        }
        movePaths(in: dest, from: b.sourceDir, to: dest.path)
        return nil
    }

    // cp -R src/. dst/ : creates dst, keeps files that only exist in dst, overwrites files that exist in both.
    private func copyMerge(_ src: URL, into dst: URL) throws {
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-R", src.path + "/.", dst.path + "/"]
        try cp.run()
        cp.waitUntilExit()
        guard cp.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    // Session files store the absolute path of the folder they were created in (e.g. scratch workspaces), and Claude
    // Code keeps each session's transcript in ~/.claude/projects/<cwd with every non-alphanumeric as "-">. When the
    // data moves from old to new, both are moved too, or the session shows a bare scratch-<date> folder and cannot resume.
    // The trailing "/" keeps ".../Claude" from matching ".../Claude-<id>".
    private func movePaths(in dest: URL, from old: String, to new: String) {
        guard old != new else { return }
        let fm = FileManager.default
        var files = [dest.appendingPathComponent("git-worktrees.json")]
        if let e = fm.enumerator(at: dest.appendingPathComponent("claude-code-sessions"), includingPropertiesForKeys: nil) {
            files += e.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        }
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        func key(_ path: String) -> String { String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }) }
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8), text.contains(old + "/") else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let cwd = obj["cwd"] as? String, cwd.hasPrefix(old + "/") {
                let from = projects.appendingPathComponent(key(cwd))
                let to = projects.appendingPathComponent(key(new + cwd.dropFirst(old.count)))
                // Claude Code shortens names over 200 characters in a way not copied here; those transcripts stay put.
                if to.lastPathComponent.count <= 200, fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                    try? fm.moveItem(at: from, to: to)
                }
            }
            try? text.replacingOccurrences(of: old + "/", with: new + "/").write(to: f, atomically: true, encoding: .utf8)
        }
    }

    // Repairs sessions that still point into another profile's folder, e.g. after a Make default from 0.1.4 or older.
    private func repairPaths(of p: Profile) {
        for q in all where q.id != p.id {
            movePaths(in: dataDir(p), from: dataDir(q).path, to: dataDir(p).path)
        }
    }

    // Merges Code-session history into Backups/<accountID>/ for every account found in the profile folder,
    // before the folder is deleted. Sessions are only added or updated, never removed from a backup.
    private func backupHistory(of p: Profile) -> Bool {
        let fm = FileManager.default
        let src = dataDir(p)
        let sessions = src.appendingPathComponent("claude-code-sessions")
        let accounts = ((try? fm.contentsOfDirectory(atPath: sessions.path)) ?? []).filter { !$0.hasPrefix(".") }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        do {
            for acct in accounts {
                let dest = backupsDir.appendingPathComponent(acct)
                try copyMerge(sessions.appendingPathComponent(acct), into: dest.appendingPathComponent("claude-code-sessions/\(acct)"))
                let scratch = src.appendingPathComponent("scratch-workspaces/\(acct)")
                if fm.fileExists(atPath: scratch.path) {
                    try copyMerge(scratch, into: dest.appendingPathComponent("scratch-workspaces/\(acct)"))
                }
                let wt = src.appendingPathComponent("git-worktrees.json")
                let wtDest = dest.appendingPathComponent("git-worktrees.json")
                if fm.fileExists(atPath: wt.path) {
                    try? fm.removeItem(at: wtDest)
                    try fm.copyItem(at: wt, to: wtDest)
                }
                let info = BackupInfo(profileName: p.name, savedAt: Date(), sourceDir: src.path)
                try enc.encode(info).write(to: dest.appendingPathComponent("info.json"))
            }
            return true
        } catch {
            return false
        }
    }

    // Main Claude processes only (not Helpers). Matches by --user-data-dir flag.
    func refreshRunning() {
        if demo { return }
        objectWillChange.send()
        let out = run("/bin/ps", ["-axo", "pid=,command="])
        var found: [String: pid_t] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { continue }
            let cmd = String(parts[1])
            guard cmd.contains("Claude.app/Contents/MacOS/Claude") else { continue }
            if let r = cmd.range(of: "--user-data-dir=") {
                let dir = String(cmd[r.upperBound...])
                if let p = profiles.first(where: { dataDir($0).path == dir }) { found[p.id] = found[p.id] ?? pid }
            } else if cmd.hasSuffix("Claude.app/Contents/MacOS/Claude") {
                found[Store.defaultProfile.id] = found[Store.defaultProfile.id] ?? pid
            }
        }
        runningPIDs = found
    }

    // Running profile: focus it. Launching again would start a second process on the same data dir.
    func launch(_ p: Profile) {
        refreshRunning()
        if let pid = runningPIDs[p.id] {
            NSRunningApplication(processIdentifier: pid)?.activate()
            sendReopen(to: pid)
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return }
        repairPaths(of: p)
        let cfg = NSWorkspace.OpenConfiguration()
        // Always a new instance: if another profile is running, macOS would otherwise just focus it.
        cfg.createsNewApplicationInstance = true
        if p.id != Store.defaultProfile.id {
            cfg.arguments = ["--user-data-dir=\(dataDir(p).path)"]
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refreshRunning() }
        }
    }

    // Same Apple event a Dock click sends. activate() alone does not bring back minimized windows.
    // Sent to this pid only, so other profiles' windows are left alone.
    private func sendReopen(to pid: pid_t) {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        AESendMessage(event.aeDesc, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
    }

    // Asks GitHub for the latest release at most every 6 hours. Only shows a link; the user downloads and installs.
    func checkForUpdate() {
        guard !demo, Date().timeIntervalSince(lastUpdateCheck) > 6 * 3600,
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        lastUpdateCheck = Date()
        struct Release: Decodable { let tag_name: String; let html_url: URL }
        let api = URL(string: "https://api.github.com/repos/dika-putra/kelawdi-squad/releases/latest")!
        URLSession.shared.dataTask(with: api) { data, _, _ in
            guard let data, let r = try? JSONDecoder().decode(Release.self, from: data) else { return }
            let latest = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
            guard latest.compare(current, options: .numeric) == .orderedDescending else { return }
            DispatchQueue.main.async { self.update = (latest, r.html_url) }
        }.resume()
    }

    private func load() {
        guard let data = try? Data(contentsOf: configFile) else { return }
        if let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            defaultName = cfg.defaultName
            profiles = cfg.profiles
        } else if let list = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = list  // first-version format: plain array
        }
    }

    private func save() {
        if demo { return }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Config(defaultName: defaultName, profiles: profiles)) {
            try? data.write(to: configFile)
        }
    }

    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
