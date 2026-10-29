import SwiftUI

// "v0.1.0 (a1b2c3d)": release version and build id, for bug reports.
private let versionLabel: String = {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
    let build = info?["CFBundleVersion"] as? String ?? ""
    return build.isEmpty ? "v\(version)" : "v\(version) (\(build))"
}()

private let avatarColors: [Color] = [
    Color(red: 0.85, green: 0.43, blue: 0.27), Color(red: 0.20, green: 0.42, blue: 0.33), Color(red: 0.25, green: 0.43, blue: 0.69),
    Color(red: 0.89, green: 0.65, blue: 0.18), Color(red: 0.55, green: 0.30, blue: 0.52),
]

struct ContentView: View {
    @EnvironmentObject var store: Store
    let close: () -> Void
    @State private var managing: Bool

    init(close: @escaping () -> Void, startManaging: Bool = false) {
        self.close = close
        _managing = State(initialValue: startManaging)
    }
    @State private var adding = false
    @State private var newName = ""
    @State private var renaming: Profile?
    @State private var renameText = ""
    @State private var removing: Profile?
    @State private var makingDefault: Profile?
    @State private var restoring: Profile?
    @State private var message: String?
    @State private var loginMessage: String?
    @State private var loginTick = 0  // forces a re-render so the switch shows the real status after a change

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let u = store.update {
                Link(destination: u.url) { Label("Update available: v\(u.version). Download", systemImage: "arrow.down.circle") }
                    .font(.callout)
            }
            VStack(spacing: 6) {
                ForEach(store.all) { p in row(p) }
            }
            if let p = removing {
                removePanel(p)
            } else if let p = makingDefault {
                defaultPanel(p)
            } else if let p = restoring {
                restorePanel(p)
            } else if adding {
                addPanel
            } else {
                footer
            }
            loginRow
            credits
        }
        .padding(14)
        .frame(width: 320)
        .focusEffectDisabled()
    }


    private var header: some View {
        HStack {
            Text("Kelawdi Squad").font(.headline)
            Text(versionLabel).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Quit Kelawdi Squad")
        }
    }

    // Reads the real status on every render; the popup re-renders each time it opens.
    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Start at login").font(.callout)
                Spacer()
                Toggle("Start at login", isOn: Binding(
                    get: { _ = loginTick; return LoginItem.isEnabled },
                    set: { on in
                        loginMessage = LoginItem.set(on)
                        loginTick += 1
                        if loginMessage == nil, LoginItem.needsApproval {
                            loginMessage = "Approve Kelawdi Squad in System Settings > General > Login Items."
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if let loginMessage {
                Text(loginMessage).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var credits: some View {
        HStack(spacing: 4) {
            Text("by Dika Putra ·").foregroundStyle(.secondary)
            Link("github.com/dika-putra/kelawdi-squad", destination: URL(string: "https://github.com/dika-putra/kelawdi-squad")!)
        }
        .font(.caption2)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button { adding = true } label: { Label("Add profile", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            Spacer()
            if managing {
                Button("Done") { finishManage() }.buttonStyle(.borderedProminent).tint(.gray)
            } else {
                Button { managing = true } label: { Label("Manage", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }


    @ViewBuilder
    private func row(_ p: Profile) -> some View {
        let isDefault = p.id == Store.defaultProfile.id
        let running = store.runningPIDs[p.id] != nil
        if managing {
            manageRow(p, isDefault: isDefault, running: running)
        } else {
            Button {
                store.launch(p)
                close()
            } label: {
                HStack(spacing: 10) {
                    Avatar(profile: p, running: running)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).fontWeight(.medium)
                        if isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    ActionPill(label: running ? "Show" : (store.needsLogin(p) ? "Login" : "Open"),
                               color: running ? .green : (store.needsLogin(p) ? .orange : .accentColor))
                }
            }
            .buttonStyle(RowStyle())
            .help("Open Claude with this profile")
        }
    }

    private func manageRow(_ p: Profile, isDefault: Bool, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Avatar(profile: p, running: running)
                if renaming == p {
                    TextField("Name", text: $renameText).textFieldStyle(.roundedBorder).onSubmit { saveRename(p) }
                    Button("Save") { saveRename(p) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).fontWeight(.medium)
                        if isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
            }
            // Two columns: four labeled buttons in one row do not fit the popup width.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                tool("Rename", "pencil") { renaming = p; renameText = p.name }
                tool("Restore", "arrow.counterclockwise") { message = nil; restoring = p }
                if !isDefault {
                    tool("Make default", "star") {
                        store.refreshRunning()
                        message = store.runningPIDs.isEmpty ? nil : "Claude is still open. Close all Claude windows first, then make this profile the default."
                        makingDefault = p
                    }
                    tool("Remove", "trash", tint: .red) { store.refreshRunning(); removing = p }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func tool(_ title: String, _ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.caption).lineLimit(1).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(tint)
    }


    private var addPanel: some View {
        card {
            Text("New profile").font(.headline)
            TextField("Profile name", text: $newName).textFieldStyle(.roundedBorder).onSubmit(commitAdd)
            HStack {
                Button("Cancel") { adding = false; newName = "" }.buttonStyle(.bordered)
                Spacer()
                Button("Add", action: commitAdd).buttonStyle(.borderedProminent).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func removePanel(_ p: Profile) -> some View {
        card {
            Text("Remove \(p.name)?").font(.headline)
            if store.runningPIDs[p.id] != nil {
                note("Claude is still open with this profile. Close that Claude window first, then remove it.", .orange)
                wide("OK") { removing = nil }
            } else {
                note("Deletes this profile's login, MCP config and cache. Code session history is saved to ~/Library/Application Support/ClaudeProfileSwitcher/Backups first (one backup per Claude account). Chats on claude.ai are not affected.", .secondary)
                wide("Remove and delete all local data", prominent: true, tint: .red) { store.remove(p, deleteData: true); removing = nil }
                wide("Cancel") { removing = nil }
            }
        }
    }

    private func defaultPanel(_ p: Profile) -> some View {
        card {
            Text("Make \(p.name) the default?").font(.headline)
            if let msg = message {
                note(msg, .orange)
                wide("OK") { makingDefault = nil; message = nil }
            } else {
                note("Claude opened from Spotlight or the Dock will open this account. The two profiles swap data folders. Close all Claude windows first.", .secondary)
                wide("Make default", prominent: true) {
                    message = store.makeDefault(p)
                    if message == nil { makingDefault = nil }
                }
                wide("Cancel") { makingDefault = nil }
            }
        }
    }

    private func restorePanel(_ p: Profile) -> some View {
        let backups = store.backups()
        return card {
            Text("Restore into \(p.name)").font(.headline)
            if let msg = message {
                note(msg, msg.hasPrefix("Restored") ? .green : .orange)
                wide("OK") { restoring = nil; message = nil }
            } else if backups.isEmpty {
                note("No backups yet. A backup is made when a profile is removed.", .secondary)
                wide("OK") { restoring = nil }
            } else {
                note("Pick a backup. Its Code sessions are merged into this profile. Close this profile's Claude window first.", .secondary)
                ForEach(backups.prefix(6)) { b in
                    Button {
                        message = store.restore(b, to: p) ?? "Restored. Open the profile to check the sessions."
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.profileName).fontWeight(.medium)
                            Text("account \(b.accountID.prefix(8)) · \(pretty(b.savedAt))").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                wide("Cancel") { restoring = nil }
            }
        }
    }


    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func wide(_ title: String, prominent: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) { Text(title).frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
        } else {
            Button(action: action) { Text(title).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
        }
    }

    private func pretty(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    private func saveRename(_ p: Profile) {
        store.rename(p, to: renameText)
        renaming = nil
    }

    private func finishManage() {
        if let p = renaming { store.rename(p, to: renameText) }
        renaming = nil
        managing = false
    }

    private func commitAdd() {
        store.add(name: newName)
        newName = ""
        adding = false
    }
}

private struct Avatar: View {
    let profile: Profile
    let running: Bool

    var body: some View {
        let seed = profile.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(avatarColors[seed % avatarColors.count]).frame(width: 30, height: 30)
                .overlay(Text(String(profile.name.prefix(1)).uppercased()).font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
            if running {
                Circle().fill(Color.green).frame(width: 10, height: 10).overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
        }
    }
}

private struct ActionPill: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color))
    }
}

private struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }
}

// @State does not work on a ButtonStyle itself, so hover lives in a View.
private struct RowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.12 : 0.06))))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
