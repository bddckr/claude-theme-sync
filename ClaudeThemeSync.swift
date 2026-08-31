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
//
// Waking the Mac is the case that needs care. With appearance set to switch
// automatically the OS flips while the machine is asleep, and the *first*
// AppleInterfaceStyle read after wake comes back stale — the pre-sleep value —
// with the true one arriving on a second notification about a second later.
// Writing both in turn publishes a wrong theme and then corrects it, and Claude
// Code's watcher takes the first write and coalesces away the second, so the
// session sits on the pre-sleep theme until you toggle appearance by hand. That
// is why a notification never writes directly: it arms a settle timer, and only
// the value still standing after the burst is written.
//
// That wait is only warranted just after a wake, though — a manual toggle has
// no stale read to ride out, and a visible pause there is just lag. So we spot
// a wake by the divergence between the wall clock and uptime, and spend the
// long settle only inside that window; every other change settles in a quarter
// of a second.

class ClaudeThemeSync {
    // Every config root to keep in sync. The default lives in ~/.claude; the
    // `claude-personal` alias points CLAUDE_CONFIG_DIR at ~/.claude-personal.
    // Only roots that already exist are touched — we never create a stray
    // config directory.
    private let configRoots: [String] = [
        NSString(string: "~/.claude").expandingTildeInPath,
        NSString(string: "~/.claude-personal").expandingTildeInPath,
    ]

    // A notification arms this, and each further one re-arms it; only the value
    // standing after this much quiet is written. A manual toggle wants this as
    // close to nothing as it can get — here it exists only to collapse a
    // same-instant burst, and a quarter-second is not perceptible.
    private let settleDelay: TimeInterval = 0.25

    // Waking is the exception. The stale read and its correction land about a
    // second apart, so the settle has to outlast that or we publish the wrong
    // theme first and Claude Code latches onto it. Nobody is watching the
    // screen the instant a lid opens, so the longer wait costs nothing here.
    private let wakeSettleDelay: TimeInterval = 3

    // How long after a wake to keep using the slow settle — long enough to
    // cover the whole burst, since only its first notification sees the jump.
    private let wakeGrace: TimeInterval = 30

    // Wall-clock/uptime divergence above this means we genuinely slept, rather
    // than were merely descheduled for a moment.
    private let sleepThreshold: TimeInterval = 5

    // One re-read after the settled write, for a wake slow enough that even the
    // settle window closed on the stale value.
    private let verifyDelay: TimeInterval = 5

    // Backstop for a change that posts no notification we see at all. Costs one
    // pref read, and writes only on a genuine mismatch, so it never churns the
    // watcher — it just means no missed notification can strand a session.
    private let pollInterval: TimeInterval = 60

    private var settleTimer: Timer?
    private var verifyTimer: Timer?
    private var pollTimer: Timer?

    // Set when either the notification or the poll notices the machine slept;
    // until it passes, a notification uses the slow settle.
    private var wakeDeadline = Date.distantPast
    private var launchDate = Date()
    private var launchUptime: TimeInterval = 0
    private var lastSlept: TimeInterval = 0

    func start() {
        setvbuf(stdout, nil, _IONBF, 0) // unbuffered so the launchd log is live

        launchDate = Date()
        launchUptime = uptime()

        syncTheme(reason: "start", evenIfUnchanged: true)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.noteSleepIfAny() // so a wake that posts no notification still slows the next one
            self.syncTheme(reason: "poll")
        }
        pollTimer?.tolerance = pollInterval / 4 // let the OS coalesce our wakeups

        log("Claude Theme Sync started. Listening for appearance changes…")
        RunLoop.current.run() // keep running
    }

    // Never syncs inline — see the wake note above. Re-arming on each
    // notification collapses a burst into the one write that is actually right.
    @objc private func handleThemeChange() {
        noteSleepIfAny()
        let delay = Date() < wakeDeadline ? wakeSettleDelay : settleDelay
        log("Appearance change detected — settling for \(String(format: "%g", delay))s")
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.syncTheme(reason: "settled")
            self.verifyTimer?.invalidate()
            self.verifyTimer = Timer.scheduledTimer(withTimeInterval: self.verifyDelay, repeats: false) { [weak self] _ in
                self?.syncTheme(reason: "verify")
            }
        }
    }

    private enum WriteResult {
        case wrote
        case unchanged
        case failed
    }

    // Quiet when there was nothing to do, so the poll doesn't fill the log with
    // a line a minute. `evenIfUnchanged` is for the one-off startup line, which
    // is worth having as proof the daemon read the appearance at all.
    private func syncTheme(reason: String, evenIfUnchanged: Bool = false) {
        let base = isDarkModeEnabled() ? "dark" : "light"

        var lines: [String] = []
        for root in configRoots where directoryExists(root) {
            let themesDir = root + "/themes"
            let themePath = themesDir + "/autosync.json"
            switch writeAutoTheme(base: base, themesDir: themesDir, themePath: themePath) {
            case .wrote: lines.append("  ✓ wrote \(themePath)")
            case .unchanged: break
            case .failed: lines.append("  ✗ failed: \(themePath)")
            }
        }

        guard !lines.isEmpty || evenIfUnchanged else { return }
        log("System is \(base) (\(reason))" + (lines.isEmpty ? " — already in sync" : " — updating AutoSync theme"))
        for line in lines { log(line) }
    }

    // Seconds since boot, which on Darwin excludes time the machine spent
    // asleep. The wall clock doesn't, so the two diverge by exactly how long we
    // were out — no power-management API or AppKit dependency needed.
    private func uptime() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }

    // Cheap enough to call on every notification — two clock reads compared
    // against where they stood when we last looked, and no timer of its own.
    private func noteSleepIfAny() {
        let slept = Date().timeIntervalSince(launchDate) - (uptime() - launchUptime)
        defer { lastSlept = slept }
        guard slept - lastSlept > sleepThreshold else { return }
        wakeDeadline = Date().addingTimeInterval(wakeGrace)
        log("Woke after \(Int(slept - lastSlept))s asleep — settling slowly for \(Int(wakeGrace))s")
    }

    // Read AppleInterfaceStyle straight from the global-domain prefs, forcing a
    // resync first — UserDefaults.standard caches and can return the *old* value
    // in the notification handler. In Light mode the key is absent, not "Light".
    //
    // The resync is not enough on its own across a wake: the first read after
    // one can still hand back the pre-sleep value, which is what the settle
    // timer in handleThemeChange() exists to ride out.
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
    // Creates the themes dir and a fresh AutoSync theme if absent.
    private func writeAutoTheme(base: String, themesDir: String, themePath: String) -> WriteResult {
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: themesDir, withIntermediateDirectories: true)
        } catch {
            log("  ! could not create \(themesDir): \(error)")
            return .failed
        }

        var theme: [String: Any] = ["name": "AutoSync", "overrides": [String: Any]()]
        if let data = fm.contents(atPath: themePath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            theme = existing
            if theme["name"] == nil { theme["name"] = "AutoSync" }
            if theme["overrides"] == nil { theme["overrides"] = [String: Any]() }
        }

        // A `base` key can only have come from an existing, parsed file, so this
        // covers "file already correct" — leave it alone rather than touch it
        // and make the watcher repaint for nothing.
        if let current = theme["base"] as? String, current == base { return .unchanged }
        theme["base"] = base

        guard let out = try? JSONSerialization.data(
            withJSONObject: theme,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return .failed }

        do {
            try out.write(to: URL(fileURLWithPath: themePath), options: .atomic)
            return .wrote
        } catch {
            log("  ! write error: \(error)")
            return .failed
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
