import Foundation

// Sync the macOS light/dark appearance into Claude Code's theme, live.
//
// Claude Code watches `<configDir>/themes/*.json` and hot-reloads a running
// session when one changes (see the official terminal-config docs). We use that
// as the live channel: we keep a custom theme file named "AutoSync" in every
// config root and flip only its `base` between "dark" and "light" when the OS
// switches. A running Claude Code session set to the "AutoSync" theme repaints
// without a restart (the repaint lands as soon as the agent goes idle).
//
// The name is deliberately NOT "auto" — Claude Code ships a built-in `auto`
// theme (startup-only OSC detection), so a custom "auto" would collide with it.
//
// This is different from writing the `theme` key in `~/.claude.json`, which
// Claude Code reads only at startup and never live-reloads.

class ClaudeThemeSync {
    // Every config root to keep in sync. The default lives in ~/.claude; the
    // `claude-personal` alias points CLAUDE_CONFIG_DIR at ~/.claude-personal.
    // Only roots that already exist are touched — we never create a stray
    // config directory.
    private let configRoots: [String] = [
        NSString(string: "~/.claude").expandingTildeInPath,
        NSString(string: "~/.claude-personal").expandingTildeInPath,
    ]

    func start() {
        setvbuf(stdout, nil, _IONBF, 0) // unbuffered so the launchd log is live

        syncTheme() // sync immediately on start

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        log("Claude Theme Sync started. Listening for appearance changes…")
        RunLoop.current.run() // keep running
    }

    @objc private func handleThemeChange() {
        log("Appearance change detected")
        syncTheme()
    }

    private func syncTheme() {
        let base = isDarkModeEnabled() ? "dark" : "light"
        log("System is \(base) — updating AutoSync theme")

        for root in configRoots where directoryExists(root) {
            let themesDir = root + "/themes"
            let themePath = themesDir + "/autosync.json"
            if writeAutoTheme(base: base, themesDir: themesDir, themePath: themePath) {
                log("  ✓ \(themePath)")
            } else {
                log("  ✗ failed: \(themePath)")
            }
        }
    }

    // Read AppleInterfaceStyle straight from the global-domain prefs, forcing a
    // resync first — UserDefaults.standard caches and can return the *old* value
    // in the notification handler. In Light mode the key is absent, not "Light".
    private func isDarkModeEnabled() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue(
            "AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication
        ) as? String
        return style == "Dark"
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // Update only `base`, preserving any `name`/`overrides` the user has set.
    // Creates the themes dir and a fresh Auto theme if absent.
    private func writeAutoTheme(base: String, themesDir: String, themePath: String) -> Bool {
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: themesDir, withIntermediateDirectories: true)
        } catch {
            log("  ! could not create \(themesDir): \(error)")
            return false
        }

        var theme: [String: Any] = ["name": "AutoSync", "overrides": [String: Any]()]
        if let data = fm.contents(atPath: themePath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            theme = existing
            if theme["name"] == nil { theme["name"] = "AutoSync" }
            if theme["overrides"] == nil { theme["overrides"] = [String: Any]() }
        }

        if let current = theme["base"] as? String, current == base,
           fm.fileExists(atPath: themePath) {
            return true // already correct — avoid a redundant write / watcher churn
        }
        theme["base"] = base

        guard let out = try? JSONSerialization.data(
            withJSONObject: theme,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return false }

        do {
            try out.write(to: URL(fileURLWithPath: themePath), options: .atomic)
            return true
        } catch {
            log("  ! write error: \(error)")
            return false
        }
    }

    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func log(_ message: String) {
        print("[\(stamp.string(from: Date()))] \(message)")
    }
}

// Main
let sync = ClaudeThemeSync()
sync.start()
