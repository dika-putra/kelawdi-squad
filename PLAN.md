# Kelawdi Squad: Plan

A native Swift macOS menu bar app that launches Claude Desktop with different accounts. One profile = one separate data directory.

Claim tags used below: [FACT] read in code or docs, or ran it. [INFERENCE] reasoning, with a confidence level. Anything not checked is marked "unverified".

## How an account is linked to Claude Desktop

There is no link at the app level. The switcher never touches credentials.

1. A new profile is an empty folder, for example `.../Claude-<id>`.
2. Claude Desktop is launched with `--user-data-dir=<that folder>`.
3. Because the folder is empty, Claude Desktop shows its login screen. The user signs in with the account they want (the normal browser flow).
4. The login session (Cookies, Local Storage, and so on) is stored in that folder. The next launch signs in directly.

So the "account" is a side effect of which folder is used. The app only stores: id, name, folder path.

[FACT] Claude Desktop on this Mac is an Electron app (it has `Electron Framework.framework`), and its data directory `~/Library/Application Support/Claude` holds `Cookies`, `Local Storage`, `Session Storage`, and more.
[FACT] The `--user-data-dir` flag is honored by Claude Desktop on macOS (tested in Phase 0).

## Features

- Menu bar icon (macOS; Windows in a separate repo later). No main window, no Dock icon.
- Click the icon: a popup lists the profiles.
- Click a profile: launch Claude Desktop with that profile. A running profile shows **Show** and is brought to the front, including a minimized window.
- **Add profile**: enter a name, then **Login** on first launch.
- **Manage** mode: Rename, Restore, Make default, Remove (labeled buttons, two-column grid).
- The default profile always exists and points to Claude's original data directory (launched without the flag), so an account that is already signed in needs no migration. It can be renamed and can be moved to another profile.
- The popup header shows the version and build id (for example `v0.1.4 (014197d)`). The footer shows the author and a link to the repository.

## Data model

`profiles.json` in the app config directory (`~/Library/Application Support/ClaudeProfileSwitcher/profiles.json`):

```json
{ "defaultName": "Default", "profiles": [{ "id": "a1b2c3d4", "name": "Work" }] }
```

- The data folder is `<base>/Claude-<id>`. The id, not the name, names the folder, so renaming only changes the label and never moves a folder.
- The default profile is not stored as a profile. It is hard-coded (id `default`, folder `Claude`). Only its name is stored (`defaultName`). It cannot be removed.
- The first version of the file was a plain array of profiles. The app still reads that format.

## Launch

- macOS: `NSWorkspace.openApplication` with `createsNewApplicationInstance = true` and the argument `--user-data-dir=<folder>` (the default profile gets no argument). This is the same as `open -n -a Claude --args --user-data-dir=<folder>`.
- Windows: run `Claude.exe --user-data-dir=<folder>`. The location of the exe still has to be found (see Risks).
- Several profiles can run at the same time (proven in Phase 0).
- [FACT] `open -n` for a profile that is already running starts another Claude process on the same data directory, and that process stays alive. Two processes on one data directory risk corrupting data. The app therefore detects running profiles first (it reads `ps` output and matches `--user-data-dir=<folder>`, and a main process without the flag is the default profile) and only focuses the existing window.
- Always starting a new instance matters: without it, if another profile is running, macOS only focuses that Claude instead of opening the requested profile. This bug was found in testing.
- Show: `NSRunningApplication.activate()` plus a "reopen" Apple event (`kAEReopenApplication`) sent to that process only, the same event a Dock click sends. `activate()` alone does not bring back a minimized window. macOS may ask once for Automation permission; `NSAppleEventsUsageDescription` is set in `Info.plist`. Confirmed working by the user.

## Removing a profile

One action: "Remove and delete all local data", explained in the confirmation panel. The panel is inline because a system dialog closes the menu bar popup before its buttons can be clicked. A "keep data" option was dropped because an orphaned folder cannot be attached to a new profile (a new id means a new folder).
- Refused while Claude for that profile is running (the panel shows a warning).
- Only deletes the `Claude-<id>` folder directly under `~/Library/Application Support` (the path is validated). The default profile cannot be removed.
- Deleted: login (Cookies, Local Storage), MCP config, cache, the Code session list, scratch workspaces.
- Not deleted: chats on claude.ai (they live in the Anthropic account), Code transcripts in `~/.claude/projects` (shared by all profiles), repositories on disk.

### Code history backup before removal

One backup per Claude account, not one per removal. The backup key is the account id, which is the folder name under `claude-code-sessions/`. Email is not used: no email field exists in the profile folder's config or session files that were inspected, while the account id is always present, stable, and unique.
- [FACT] The same account produced the same id across five different profile folders, and two different accounts produced two different ids.
- [INFERENCE - medium] The id is assigned by Anthropic and should stay the same for the life of the account. No official documentation was found.
- Location (the `Library` folder is hidden in Finder): `~/Library/Application Support/ClaudeProfileSwitcher/Backups/<account id>/`
- Contents: `claude-code-sessions/<account id>/`, `scratch-workspaces/<account id>/`, `git-worktrees.json`, and `info.json` (profile name, save time, source folder).
- Update rule: the backup is merged, not replaced. New sessions are added, sessions with the same id are overwritten by the newer version, and sessions already in the backup are never removed. This is intentional: replacing the backup with the latest copy could delete older sessions when the last removed profile had fewer of them. Pure replace would be a small change in `backupHistory`.
- If the copy fails, the profile and its data are not deleted.
- Backups from the first version (folders named `<name>-<id>-<date>`) are not recognized and were not migrated. Copy them by hand with `cp -R <backup>/. <profile folder>/`.

Restore: Manage > Restore > pick an account backup. Requirements: the target profile has been opened once and its Claude is closed. The app merges the backup into the profile folder and then rewrites absolute paths of the old folder (taken from `info.json`) inside the session files to the target path, and moves the matching transcript folder under `~/.claude/projects`.
Proven (manual restore, 2026-10-17): the Code session list reappears in a new profile. Not proven: restore through the button, and sessions that worked in a scratch workspace.

## Make default

Default = the account that opens when Claude is started from Spotlight or the Dock = the contents of the `Claude` folder. Moving it means swapping folders: `Claude` -> `Claude-swap-tmp`, `Claude-<id>` -> `Claude`, `Claude-swap-tmp` -> `Claude-<id>`, then swapping the names of the two profiles so each name keeps following its account. If a step fails, the earlier steps are rolled back. It is refused when any Claude process is running, when a leftover `Claude-swap-tmp` exists, or when the target profile has never been opened (its folder does not exist).
Tested by the user on 2026-10-18 and it worked.
Risks: if the app is interrupted between the renames, `Claude` can be missing while the data sits in `Claude-swap-tmp` (nothing is lost, but it must be renamed back by hand).
Code sessions that used a scratch workspace store the absolute path of their folder, and Claude Code keeps their transcripts in `~/.claude/projects/<that path with non-alphanumerics as "-">`. After the swap, both are moved to the new folder. Up to 0.1.4 they were not, so sessions showed a bare `scratch-<date>` folder and could not resume (issue #1); launching a profile from the popup repairs those. Transcript folder names over 200 characters are not moved (Claude Code shortens them in a way the app does not copy).

## Stack and decisions

Native Swift (AppKit + SwiftUI), SwiftPM, no Xcode project. The menu bar icon is an `NSStatusItem`. The popup is an `NSPanel` placed under the icon by the app itself: both `MenuBarExtra` and `NSPopover` repositioned incorrectly when the content size changed. The anchor is read once when the icon is clicked and every resize is positioned from it.
`build.sh` builds a universal binary (arm64 + x86_64) and creates `build/Kelawdi Squad.app` with `LSUIElement` (no Dock icon), signed ad hoc (or with `SIGN_ID`). `make-dmg.sh` builds the app and packages `build/Kelawdi-Squad-<version>-macOS.dmg`.

Decision log:
- 2026-10-17: macOS first because it was urgent. Windows will be a separate repo later. Tauri and Flutter were considered and not used.
- 2026-10-18: renamed from "Claude Profiles" to "Keladi Hub". Reason: the name did not contain the "Claude" trademark, so it did not look like an official Anthropic product. A sound-alike name ("Klewdi") was rejected for a public repository. The README carries a not-affiliated disclaimer.
- 2026-10-19: renamed again to **Kelawdi Squad** (author's choice: a pun on "Claude" and "keladi", the plant; "Squad" for a small group of profiles). This is closer in sound to the "Claude" mark than "Keladi" was, which was discussed and accepted by the author; the not-affiliated disclaimer stays. "Klewd" was rejected (it sounds like the existing proxy project ClewdR and reads as "lewd"). The bundle id changed to `com.dienn.kelawdisquad` and the repository to `kelawdi-squad`, so the Automation permission and Start at login have to be granted again. Old releases (v0.1.1 to v0.1.3) keep the old name.
- 2026-10-18: logo "captain": a round face with a white crescent mustache as the hub, with five colored nodes as the crew (design `captain` in `assets/make-icons.swift`, which also contains `hub`, `pinwheel`, and `leaf`). The menu bar icon is a single-color template image. The logo is original; it does not copy any existing emblem.
- 2026-10-19 roadmap review (grilling session), agreed with the author:
  - Audience: a personal tool shared as is. No support promise. The README says so.
  - Scope: Claude Desktop only. Research on other AI desktop apps (secondary sources, nothing tested here): VS Code fork editors such as Cursor are Electron and may work only partly (MCP config can leak between folders); Gemini's Mac app is native Swift, so no data-folder flag; ChatGPT desktop is disputed (native or Electron) and OpenAI says account switching is web only; Perplexity has its own switcher. An adapter architecture only gets built after a second app passes a local test (`open -n -a <app> --args --user-data-dir=<folder>`).
  - Windows: not started until there is a real need and a Windows machine to test on.
  - Restore for scratch-workspace sessions stays a documented limitation.
  - Notarization: not now. Revisit if several outside users are blocked by the macOS warning.
  - Start at login: added, default off, through `SMAppService.mainApp` (`LoginItem.swift`). Tested by the author on 2026-10-22: it works for the ad-hoc signed build installed in the Applications folder. If macOS refuses, the popup shows the error.
- 2026-10-29: apps that use the Claude Code login (for example OpenBot, which reads `~/.claude.json` and the `Claude Code-credentials` Keychain entry) see one account for every profile: the last one that signed in to Claude Code. Out of scope; separating it would need a `CLAUDE_CONFIG_DIR` per profile.
- 2026-10-29: the popup checks the latest GitHub release (at most every 6 hours) and shows a download link when it is newer. No automatic install, because the app is not notarized.
- 2026-10-18: the repository is public under the MIT license. Releases ship as a DMG, ad-hoc signed and not notarized (see Distribution).

Structure:
- `Sources/KelawdiSquad/Store.swift`: profile model, `profiles.json`, running-process detection (`ps`), launch and focus, safe removal, backup, restore, swap default, demo data for screenshots.
- `Sources/KelawdiSquad/ContentView.swift`: popup content: list, add, manage mode, confirmation panels.
- `Sources/KelawdiSquad/LoginItem.swift`: Start at login through `SMAppService`.
- `Sources/KelawdiSquad/App.swift`: menu bar icon, popup panel, and the `--screenshot <dir>` mode.
- `assets/`: icons, `make-icons.swift`, and README screenshots.

## Distribution

- Universal binary, ad-hoc signed, **not notarized**. macOS blocks it on first launch; the user has to choose Open Anyway in System Settings > Privacy & Security.
- Notarization needs a Developer ID Application certificate from the paid Apple Developer Program. The Apple Development certificate on the dev machine cannot be used for it, and certificates that belong to other accounts must not be used for this project. Not planned for now.
- Every release page lists the SHA-256 of the DMG.
- Releases: the only published release is v0.1.4 (Kelawdi Squad, DMG). The older releases v0.1.0 to v0.1.3 (zip and DMG, under the names Claude Profiles and Keladi Hub) were deleted on 2026-10-19; their git tags remain.
- The bundle id changed with the rename, so macOS treats Kelawdi Squad as a new app: the Automation permission is asked again and Start at login has to be switched on again. People coming from Keladi Hub should turn off Start at login in the old app and trash it first.

README screenshots are generated by the app itself: `KelawdiSquad --screenshot <dir>` shows the panel with demo data over a plain backdrop, captures its own window, and quits. Demo mode never reads or writes the real config.

## Incident 2026-10-17: build deleted by macOS

An attempt to restore minimized windows through the Accessibility API (`AXUIElement`), signed with an Apple Development certificate, ended with the `.app` being deleted by macOS as malware. The detection name and the exact cause are unknown (the system log did not record a reason). The Accessibility code and the `/tmp` debug log were removed and the signature went back to ad hoc. Restoring minimized windows was later solved with the reopen Apple event instead (see Launch). If an Accessibility approach is tried again, ask for permission only once and do not reuse the build that was deleted.

## Status

- Phase 0 (macOS spike): done. Windows is not tested.
- macOS app: done and released (v0.1.4). Launch, focus, add, rename, remove, restore, make default, backups, and the popup UI are implemented. Tested by the user: launch, focus, add, rename, remove, make default, popup layout and positioning.
- Not done by decision: restore for scratch-workspace sessions, notarization, the Windows version, support for other AI apps.
- Start at login: tested by the author, works. Not checked: whether a login item left behind by a deleted app stays listed in Login Items.

Phase 0 results on macOS, 2026-10-17:
- Proven: the `--user-data-dir` flag works; a new folder starts empty and shows the login screen; a second account signs in separately; the original account stays signed in; the session survives closing and reopening; chat works normally.
- Proven: `claude_desktop_config.json` is per folder, so MCP configuration is per profile and a new profile starts without MCP servers.
- Proven: relaunching a running profile creates a duplicate process, so the app checks first and only focuses.
- Proven: Claude Desktop keeps a single `Claude Safe Storage` Keychain entry shared by all profiles, and a copied profile folder under another name stayed signed in.
- Not tested: Windows (exe location, MSIX).

Out of scope (add if needed): a wrapper `.app` per profile with its own Dock icon, a "logged in" status check, history import.

## Handoff: how to continue

Current state: v0.1.4 is released and everything is pushed to `main`. The tree is clean.

Common tasks:
- Build the app: `./build.sh`, then open `build/Kelawdi Squad.app`. Quit a running copy first (process name `KelawdiSquad`).
- Build the DMG: `./make-dmg.sh`. Build from a clean git tree so the build id in the popup header is a plain commit hash without `-dirty`.
- Regenerate icons: `swift assets/make-icons.swift assets captain`, then `iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns` and delete `assets/AppIcon.iconset`. The script writes the iconset and the menu bar PNG; it does not run `iconutil` itself.
- Regenerate README screenshots after any UI change: build from a clean tree, run `KelawdiSquad --screenshot <dir>` (demo data, real config untouched), copy `popup.png` and `manage.png` to `assets/screenshots/`.
- Release: bump `CFBundleShortVersionString` in `build.sh`, commit and push, run `./make-dmg.sh`, check the DMG (mount it, `lipo -info` should list arm64 and x86_64), then `gh release create vX.Y.Z <dmg> --target main` with English notes that include the SHA-256 and the "not signed by Apple" instructions.

Things that are easy to get wrong:
- Never publish a build that was made from a dirty tree.
- A bundle id change makes macOS treat the app as new: permissions and Start at login are asked again.
- Show relies on a reopen Apple event. Do not go back to the Accessibility API (see the 2026-10-17 incident).
- The popup is a custom `NSPanel`. Do not switch it back to `MenuBarExtra` or `NSPopover` (they moved when the content size changed).
- The config folder is still named `ClaudeProfileSwitcher`, and `profiles.json` may still be in the first plain-array format. Keep reading both.
- Deleting a profile folder or a backup is permanent. Keep the path checks in `Store.remove`.

Backlog, in rough priority order (all optional, see the decision log for why each is deferred):
1. Check whether a login item left behind by a deleted app stays listed in Login Items, then update the README.
2. Restore for scratch-workspace sessions (needs real data to test).
3. A second AI desktop app: test `open -n -a <app> --args --user-data-dir=<folder>` locally first; only then consider an adapter design.
4. Windows, in a separate repository, once there is a Windows machine to test on.
5. Notarization, which needs a Developer ID certificate from the paid Apple Developer Program.

## Risks and unverified items

- Windows: Claude Desktop may be installed as an MSIX / Store app. The exe path may be unstable and launching with arguments may be restricted. Unverified; check when the Windows version starts.
- All Claude instances share one Dock or taskbar icon, so it is hard to tell which window belongs to which account. The account shown inside Claude Desktop is the only hint.
- Keychain: [INFERENCE - medium] Electron `safeStorage` uses one shared key in the Keychain and the encrypted tokens stay in the data folder, so folders can be renamed or copied on the same Mac. Deleting the Keychain entry would sign out every profile.
- Claude Desktop updates can change the app name, paths, or the behavior of the flag.
- Anthropic's Terms of Service on multiple accounts. Read on 2026-10-18 through a page summary (not a full read): the Consumer Terms do not address holding more than one account and prohibit sharing account access and automated or non-human access; the Usage Policy prohibits creating multiple accounts to avoid detection, evading bans, and reselling access. Nothing found that forbids two accounts per person. Using several accounts to avoid usage limits is the risky pattern. A work account on a company email can be linked to the employer's enterprise account. Not legal advice.
- Trademark: the name and logo avoid the "Claude" mark and the README says the project is not affiliated with Anthropic. Anthropic's guidelines say third parties may not imply affiliation. No rule specific to app names was found. Unverified whether the name "Kelawdi Squad" is used elsewhere.
- Removing a data folder is permanent. The path is validated (only `Claude-<id>` directly under the base) so that no other folder can be deleted.
