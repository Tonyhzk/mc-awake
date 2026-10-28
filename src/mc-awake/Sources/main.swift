import Cocoa
import Darwin
import ServiceManagement
import UserNotifications

// McAwake — a menu bar utility that keeps your Mac awake, even with the
// lid closed.
//
// macOS force-sleeps a MacBook when the lid closes unless it is docked to
// AC power AND an external display. Tools like caffeinate or Amphetamine
// cannot prevent that — their assertions only stop *idle* sleep. The only
// switch that survives a lid close is `pmset disablesleep`, which needs
// admin rights. McAwake wraps it in three modes:
//
//   Always Awake : never sleeps — with a low-battery guard (a root daemon
//                  restores normal sleep below 15% on battery, so a
//                  forgotten Mac can't run itself flat; re-arms at 18%
//                  or on AC)
//   Smart Auto   : the same daemon in "auto" mode — awake on AC power,
//                  normal sleep on battery (bag-safe)
//   Normal Sleep : disablesleep 0 — the macOS default
//
// The daemon is installed with one macOS admin-password prompt.

// Single source of truth for the version is Resources/Info.plist —
// scripts/release.sh reads the same key to cut releases.
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let daemonLabel = "com.mcawake.auto"
let daemonPlistPath = "/Library/LaunchDaemons/com.mcawake.auto.plist"
let daemonDirectory = "/Library/Application Support/McAwake"
let daemonScriptPath = "\(daemonDirectory)/mcawake-auto.sh"
let daemonStateDirectory = "/var/db/com.mcawake"
let daemonModePath = "\(daemonStateDirectory)/mode"
let daemonControlPath = "\(daemonStateDirectory)/control"

// MARK: - System state helpers

@discardableResult
func shell(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    // Read BEFORE waitUntilExit: waiting first deadlocks the moment a
    // command's output exceeds the 64KB pipe buffer (the child blocks
    // writing, we block waiting). Bit for real when `ps axo` crossed
    // 64KB and froze all detection — Claude section vanished.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func sleepDisabledNow() -> Bool? {
    for line in shell("/usr/bin/pmset -g").split(separator: "\n")
    where line.contains("SleepDisabled") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else { return nil }
        switch fields[1] {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
    return nil
}

func powerSnapshot() -> PowerSnapshot {
    PowerSnapshot(output: shell("/usr/bin/pmset -g ps"))
}

func daemonArguments() -> [String]? {
    guard let data = FileManager.default.contents(atPath: daemonPlistPath),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["ProgramArguments"] as? [String]
}

func reusableDaemonConfigured() -> Bool {
    guard let args = daemonArguments(), args.count == 4 else { return false }
    return args[1] == daemonScriptPath && args[2] == "--uid" && args[3] == String(getuid())
}

func installedDaemonMode() -> String? {
    guard let args = daemonArguments() else { return nil }
    if args.count == 4 && args[2] == "--uid" {
        guard let mode = try? String(contentsOfFile: daemonModePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              ["normal", "auto", "always"].contains(mode) else { return nil }
        return mode
    }
    return args.contains("always") ? "always" : "auto"
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The plist can exist while the daemon itself is dead (failed bootstrap,
/// crash). pgrep sees root processes from a user session, no privileges
/// needed — so the menu can tell the truth instead of trusting the file.
func daemonProcessRunning() -> Bool {
    !shell("/usr/bin/pgrep -f 'mcawake-auto.sh'").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// True when the installed daemon script differs from the copy bundled in
/// this app version — i.e. an app upgrade shipped a newer daemon and the
/// user hasn't re-selected a mode yet.
func daemonScriptOutdated() -> Bool {
    guard let res = Bundle.main.resourcePath,
          FileManager.default.fileExists(atPath: daemonScriptPath) else { return false }
    let installed = shell("/sbin/md5 -q \(shellQuote(daemonScriptPath))")
    let bundled = shell("/sbin/md5 -q \(shellQuote("\(res)/mcawake-auto.sh"))")
    return !installed.isEmpty && !bundled.isEmpty && installed != bundled
}

// MARK: - Local service detection (v1.3)
// Read-only: shows what the always-awake Mac is actually hosting. Process
// name + port + PID only — NEVER command lines (they can carry secrets,
// e.g. tunnel tokens). Servers running as root are not visible from a
// user-session lsof; documented limitation.

struct LocalService: Equatable {
    let name: String
    let pid: Int
    let ports: [Int]
}

struct Tunnel: Equatable {
    let name: String
    let pid: Int
}

/// System/browser processes that listen on ports but aren't "your servers".
let serviceDenylist = [
    "rapportd", "controlce", "sharingd", "identityservice", "airplay",
    "ampdevice", "continuity", "assistantd", "corespeech", "remoted",
    "google", "chrome", "safari", "firefox", "arc", "brave", "msedge",
    "code", "electron", "dropbox", "onedrive", "adobe", "spotify",
    "steam", "discord", "zoom", "teams", "slack",
]

func detectLocalServices() -> [LocalService] {
    var byPid: [Int: (name: String, ports: Set<Int>)] = [:]
    let out = shell("/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null")
    for line in out.split(separator: "\n").dropFirst() {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (LISTEN)
        guard cols.count >= 10, let pid = Int(cols[1]) else { continue }
        let name = String(cols[0]).replacingOccurrences(of: "\\x20", with: " ")
        if serviceDenylist.contains(where: { name.lowercased().hasPrefix($0) }) { continue }
        let addr = cols[cols.count - 2]
        guard let portStr = addr.split(separator: ":").last, let port = Int(portStr) else { continue }
        byPid[pid, default: (name, [])].ports.insert(port)
    }
    return byPid
        .map { LocalService(name: $0.value.name, pid: $0.key, ports: $0.value.ports.sorted()) }
        .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
}

/// Tunnel clients dial out rather than listen — detect by process name.
func detectTunnels() -> [Tunnel] {
    var found: [Tunnel] = []
    for tool in ["cloudflared", "ngrok"] {
        let out = shell("/usr/bin/pgrep -x \(tool) | /usr/bin/head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = Int(out) { found.append(Tunnel(name: tool, pid: pid)) }
    }
    return found
}

// MARK: - Claude Code terminal sessions (v1.7)
// Interactive `claude` CLI processes: comm's basename is "claude" with a
// real controlling tty (background helpers like bg-pty-host run on ?? and
// are skipped). cwd via lsof tells WHICH project each terminal is in.

struct ClaudeSession: Equatable {
    let pid: Int
    let tty: String
    let etime: String
    let cwd: String
    let name: String?     // the session's given name (from /rename or auto)
    let busy: Bool

    // etime ticks every second and busy flips on every turn — comparing
    // either would make refreshes look like changes and reintroduce the
    // rebuild stutter. Identity is pid + tty + cwd + name.
    static func == (l: ClaudeSession, r: ClaudeSession) -> Bool {
        l.pid == r.pid && l.tty == r.tty && l.cwd == r.cwd && l.name == r.name
    }
}

// Claude Code writes ~/.claude/sessions/<pid>.json with the session's
// name ("mcawake"), status ("busy"/"idle"), cwd, and ids — a direct
// pid→name mapping. Stale files for dead pids exist but are never read
// (we only look up pids found live via ps).
func claudeSessionMeta(pid: Int) -> (name: String?, busy: Bool) {
    let path = "\(NSHomeDirectory())/.claude/sessions/\(pid).json"
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (nil, false) }
    return (obj["name"] as? String, (obj["status"] as? String) == "busy")
}

func detectClaudeSessions() -> [ClaudeSession] {
    var found: [(pid: Int, tty: String, etime: String)] = []
    let out = shell("/bin/ps axo pid,tty,etime,comm")
    for line in out.split(separator: "\n").dropFirst() {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 4,
              let pid = Int(cols[0]),
              cols[1].hasPrefix("ttys") else { continue }
        // comm is whatever the process was invoked as — bare "claude" when
        // resolved via PATH, an absolute path when launched by one (both
        // occur on the same machine), so match the basename. NOT ucomm:
        // Claude Code rewrites its process title, so ucomm is the version
        // string ("2.1.220"), which matches nothing.
        let comm = cols[3...].joined(separator: " ")
        guard comm == "claude" || comm.hasSuffix("/claude") else { continue }
        found.append((pid, String(cols[1]), String(cols[2])))
    }
    guard !found.isEmpty else { return [] }

    // ONE lsof for all sessions (-Fpn: p<pid> / n<cwd> pairs) — per-pid
    // lsof calls were the main source of a 1–2s menu-open lag.
    var cwdByPid: [Int: String] = [:]
    let pidList = found.map { String($0.pid) }.joined(separator: ",")
    var currentPid: Int?
    for line in shell("/usr/sbin/lsof -a -p \(pidList) -d cwd -Fpn 2>/dev/null")
        .split(separator: "\n") {
        if line.hasPrefix("p") { currentPid = Int(line.dropFirst()) }
        else if line.hasPrefix("n"), let pid = currentPid {
            cwdByPid[pid] = String(line.dropFirst())
        }
    }
    return found
        .map { proc -> ClaudeSession in
            let meta = claudeSessionMeta(pid: proc.pid)
            return ClaudeSession(pid: proc.pid, tty: proc.tty, etime: proc.etime,
                                 cwd: cwdByPid[proc.pid] ?? "?",
                                 name: meta.name, busy: meta.busy)
        }
        .sorted { $0.tty < $1.tty }
}

// MARK: - Privileged execution

enum AdminResult {
    case success
    case cancelled
    case failed(String)
}

/// Runs a shell command as root via the standard macOS admin-password
/// dialog.
///
/// Executed IN-PROCESS with NSAppleScript so the dialog says
/// "McAwake wants to make changes" (an osascript subprocess made it say
/// "osascript wants to make changes" — technically identical, but scary
/// to anyone who doesn't know what osascript is; live user question).
/// NSAppleScript is main-thread-only per Apple, so the runloop blocks
/// while the password dialog is up — acceptable: the action is always
/// user-initiated and the dialog has their full attention.
func runAdmin(_ cmd: String, completion: @escaping (AdminResult) -> Void) {
    let escaped = cmd
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let src = "do shell script \"\(escaped)\" with administrator privileges"

    DispatchQueue.main.async {   // let the menu close first
        guard let script = NSAppleScript(source: src) else {
            completion(.failed("Unable to create the authorization request."))
            return
        }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        guard let err else {
            completion(.success)
            return
        }
        let num = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
        let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript error \(num)"
        completion(num == -128 ? .cancelled : .failed(msg))
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
                   UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var watchTimer: Timer?

    // Notifications: UN center when authorized; osascript fallback only
    // when registration ERRORS (ad-hoc signing quirks) — an explicit user
    // denial is respected, never bypassed.
    var notificationsDenied = false
    var useFallbackNotify = false

    // Sleep-state transition tracking (guard trip / external change).
    var prevAwake: Bool?
    var batteryGuard = BatteryGuardTracker()
    var lastModeChangeAt = Date.distantPast

    // Detection caches: the menu builds INSTANTLY from these; a
    // background refresh kicks off on every open and repopulates the
    // still-open menu in place when it lands (NSMenu supports live
    // mutation). Building synchronously from live lsof/ps caused a 1–2s
    // menu-open lag, reported by a real user.
    var cachedServices: [LocalService] = []
    var cachedTunnels: [Tunnel] = []
    var cachedSessions: [ClaudeSession] = []
    var menuIsOpen = false
    var refreshInFlight = false

    // Service watch: identity is the PORT (pids change across restarts);
    // tunnels are watched by process name. Persisted in UserDefaults.
    var watchedPorts: Set<Int> = []
    var watchedTunnels: Set<String> = []
    var portLabels: [Int: String] = [:]
    var lastPortUp: [Int: Bool] = [:]
    var lastTunnelUp: [String: Bool] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // Single instance: a second copy would just add a second owl.
        let mine = Bundle.main.bundleIdentifier ?? "com.mcawake.app"
        if NSRunningApplication.runningApplications(withBundleIdentifier: mine)
            .filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
            .count > 0 {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshIcon() }

        loadWatches()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, err in
            if err != nil {
                self?.useFallbackNotify = true      // registration broken → osascript
            } else if !granted {
                self?.notificationsDenied = true    // user said no → stay quiet
            }
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.runWatchChecks()
        }
        watchTimer?.tolerance = 10

        refreshDetectionCaches()
        offerLoginItemOnFirstRun()
    }

    var refreshCompletions: [() -> Void] = []

    func refreshDetectionCaches(then: (() -> Void)? = nil) {
        // Queue completions instead of dropping them: the old early
        // return threw away the callback when a refresh was already in
        // flight — an open menu waiting on it never updated (second bug
        // found while chasing the pipe deadlock).
        if let then { refreshCompletions.append(then) }
        if refreshInFlight { return }
        refreshInFlight = true
        DispatchQueue.global().async { [weak self] in
            let services = detectLocalServices()
            let tunnels = detectTunnels()
            let sessions = detectClaudeSessions()
            DispatchQueue.main.async {
                guard let self else { return }
                self.cachedServices = services
                self.cachedTunnels = tunnels
                self.cachedSessions = sessions
                self.refreshInFlight = false
                let pending = self.refreshCompletions
                self.refreshCompletions = []
                pending.forEach { $0() }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func notify(_ title: String, _ body: String) {
        if notificationsDenied { return }
        if useFallbackNotify {
            let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
            shell("/usr/bin/osascript -e 'display notification \"\(esc(body))\" with title \"\(esc(title))\"'")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Watch persistence

    func loadWatches() {
        let d = UserDefaults.standard
        watchedPorts = Set(d.array(forKey: "WatchedPorts") as? [Int] ?? [])
        watchedTunnels = Set(d.array(forKey: "WatchedTunnels") as? [String] ?? [])
        if let raw = d.dictionary(forKey: "WatchedPortLabels") as? [String: String] {
            for (k, v) in raw { if let p = Int(k) { portLabels[p] = v } }
        }
    }

    func saveWatches() {
        let d = UserDefaults.standard
        d.set(Array(watchedPorts), forKey: "WatchedPorts")
        d.set(Array(watchedTunnels), forKey: "WatchedTunnels")
        d.set(Dictionary(uniqueKeysWithValues: portLabels.map { (String($0.key), $0.value) }),
              forKey: "WatchedPortLabels")
    }

    // MARK: Watch checks (every 60s)
    // Transitions only: the first observation of a watch primes silently,
    // so an app relaunch before services start doesn't false-alarm.

    func runWatchChecks() {
        guard !watchedPorts.isEmpty || !watchedTunnels.isEmpty else { return }
        // Detection runs OFF the main thread (an lsof scan blocking the
        // runloop is exactly the lag bug the menu had); state updates and
        // notifications hop back to main. The caches refresh as a side
        // effect — the watch cycle already pays for the lsof, so the menu
        // stays ≤60s fresh even when never opened.
        DispatchQueue.global().async { [weak self] in
            let liveServices = detectLocalServices()
            let liveTunnelList = detectTunnels()
            DispatchQueue.main.async {
                self?.applyWatchResults(liveServices, liveTunnelList)
            }
        }
    }

    func applyWatchResults(_ liveServices: [LocalService],
                           _ liveTunnelList: [Tunnel]) {
        cachedServices = liveServices
        cachedTunnels = liveTunnelList
        let livePorts = Set(liveServices.flatMap { $0.ports })
        for port in watchedPorts {
            let up = livePorts.contains(port)
            if let prev = lastPortUp[port], prev != up {
                let label = portLabels[port] ?? "service"
                notify(up ? "✅ \(label) :\(port) is back" : "⚠️ \(label) :\(port) went down",
                       up ? "Listening again on localhost:\(port)."
                          : "Nothing is listening on localhost:\(port) anymore.")
            }
            lastPortUp[port] = up
        }
        let liveTunnels = Set(liveTunnelList.map { $0.name })
        for t in watchedTunnels {
            let up = liveTunnels.contains(t)
            if let prev = lastTunnelUp[t], prev != up {
                notify(up ? "✅ \(t) tunnel is back" : "⚠️ \(t) tunnel went down",
                       up ? "The \(t) process is running again."
                          : "The \(t) process is no longer running.")
            }
            lastTunnelUp[t] = up
        }
        lastPortUp = lastPortUp.filter { watchedPorts.contains($0.key) }
        lastTunnelUp = lastTunnelUp.filter { watchedTunnels.contains($0.key) }
        refreshIcon()   // reflect watch state in the menu bar immediately
    }

    @objc func toggleWatchPort(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let port = info["port"] as? Int else { return }
        if watchedPorts.contains(port) {
            watchedPorts.remove(port)
            lastPortUp.removeValue(forKey: port)
        } else {
            watchedPorts.insert(port)
            if let label = info["label"] as? String { portLabels[port] = label }
            lastPortUp[port] = true   // only watchable from a live listing
        }
        saveWatches()
    }

    @objc func toggleWatchTunnel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if watchedTunnels.contains(name) {
            watchedTunnels.remove(name)
            lastTunnelUp.removeValue(forKey: name)
        } else {
            watchedTunnels.insert(name)
            lastTunnelUp[name] = true
        }
        saveWatches()
    }

    // On the very first launch, enable Start at Login (visible and
    // revocable in the menu and in System Settings > Login Items).
    func offerLoginItemOnFirstRun() {
        let key = "McAwakeLoginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    func refreshIcon() {
        let awakeReading = sleepDisabledNow()
        let awake = awakeReading ?? false
        let mode = installedDaemonMode()
        let power = powerSnapshot()
        let ac = power.source == .ac

        // Trouble = anything the user should glance-check: a watched
        // service/tunnel currently down, or the daemon dead behind an
        // installed plist. Uses the 60s checker's cached state — no extra
        // work on the 10s tick beyond one pgrep when a daemon is expected.
        let watchDown = lastPortUp.values.contains(false) || lastTunnelUp.values.contains(false)
        let daemonDead = daemonArguments() != nil && !daemonProcessRunning()
        let trouble = watchDown || daemonDead

        // Mode-aware icon (v1.11, user feedback: switching modes must be
        // visible in the bar): 🦉 Always Awake · 🔌 Smart Auto on power
        // (awake because plugged in) · 💤 can sleep (Normal, or Smart
        // Auto on battery) · 🪫 guard tripped · ⚠️ appended on trouble.
        let guardTripped = mode == "always" && !awake && !ac
        let base: String
        var tip: String
        if guardTripped {
            base = "🪫"
            tip = "McAwake — low-battery guard tripped; re-arms when charging"
        } else if mode == "auto" {
            base = awake ? "🔌" : "💤"
            tip = awake ? "McAwake — Smart Auto: plugged in, staying awake"
                        : "McAwake — Smart Auto: on battery, normal sleep"
        } else {
            base = awake ? "🦉" : "💤"
            tip = awake ? "McAwake — your Mac will NOT sleep (even lid closed)"
                        : "McAwake — your Mac sleeps normally (lid close = sleep)"
        }
        statusItem.button?.title = trouble ? base + "⚠️" : base
        if watchDown { tip += " · a watched service is DOWN" }
        if daemonDead { tip += " · daemon not running (open menu to repair)" }
        statusItem.button?.toolTip = tip

        let guardEvent = batteryGuard.observe(mode: mode, awake: awakeReading, power: power)
        if let prev = prevAwake, Date().timeIntervalSince(lastModeChangeAt) > 25 {
            if let guardEvent {
                switch guardEvent {
                case .tripped:
                    notify("🛟 Low-battery guard tripped",
                           "Normal sleep restored so the battery can't run flat. Re-arms when charging.")
                case .rearmed:
                    notify("🦉 Staying awake again",
                           "Battery recovered or power is back — sleep is blocked again.")
                }
            } else if prev != awake && (mode == nil || mode == "normal") {
                notify("Sleep setting changed outside McAwake",
                       awake ? "disablesleep was turned ON by something else."
                             : "disablesleep was turned OFF — your Mac can sleep now.")
            }
        }
        prevAwake = awake
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(menu)   // instant, from caches
        // Refresh in the background, but only REBUILD the open menu when
        // the data actually changed — unconditional rebuilds made the
        // menu visibly stutter on every open (live user report). Data is
        // stable minute-to-minute, so the rebuild is the rare case.
        let prevServices = cachedServices
        let prevTunnels = cachedTunnels
        let prevSessions = cachedSessions
        refreshDetectionCaches { [weak self] in
            guard let self, self.menuIsOpen else { return }
            if self.cachedServices != prevServices
                || self.cachedTunnels != prevTunnels
                || self.cachedSessions != prevSessions {
                self.buildMenu(menu)
            }
        }
    }

    func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let awake = sleepDisabledNow() ?? false
        let power = powerSnapshot()
        let ac = power.source == .ac
        let mode = installedDaemonMode()  // nil | "normal" | "auto" | "always"

        // Compact status: one line, full explanation in the tooltip
        // (v1.10 lean pass — labels terse, hover for prose).
        let guardTripped = mode == "always" && !awake && !ac
        let stateLabel = guardTripped ? "🪫 Guard active" : (awake ? "🦉 Awake" : "💤 Can sleep")
        var powerLabel = ac ? "plugged in" : "battery"
        if !ac, let pct = power.batteryPercent { powerLabel += " \(pct)%" }
        let statusTip = guardTripped
            ? "Low-battery guard tripped — normal sleep allowed until charging; re-arms at 18% or on power"
            : (awake ? "Your Mac will not sleep — even with the lid closed"
                     : "Your Mac sleeps normally — closing the lid sleeps it")
        addInfo(menu, "\(stateLabel) · \(powerLabel)", tooltip: statusTip)

        // Daemon self-checks: the file can exist while the process is dead,
        // and an app upgrade can leave an older script installed. Both are
        // one click to fix (reinstalls the daemon in the same mode).
        if daemonArguments() != nil && !daemonProcessRunning() {
            let repair = NSMenuItem(title: "⚠️ Repair daemon",
                                    action: #selector(repairDaemon), keyEquivalent: "")
            repair.target = self
            repair.toolTip = "The daemon is installed but its process isn't running — click to reinstall it in the current mode"
            menu.addItem(repair)
        } else if mode != nil && daemonScriptOutdated() {
            let update = NSMenuItem(title: "⬆️ Update daemon",
                                    action: #selector(repairDaemon), keyEquivalent: "")
            update.target = self
            update.toolTip = "This app version ships a newer daemon than the installed one — click to update (one password prompt)"
            menu.addItem(update)
        }
        menu.addItem(.separator())

        addMode(menu, "🦉 Always Awake", #selector(setAlwaysAwake),
                checked: mode == "always" || (mode == nil && awake),
                tooltip: "Never sleep, plugged in or not — with the 15% battery guard (careful in a closed bag)")
        addMode(menu, "🔌 Smart Auto", #selector(setSmartAuto), checked: mode == "auto",
                tooltip: "Awake when plugged in, normal sleep on battery — bag-safe")
        addMode(menu, "💤 Normal Sleep", #selector(setNormalSleep),
                checked: mode == "normal" || (mode == nil && !awake),
                tooltip: "macOS default — closing the lid sleeps the Mac")

        menu.addItem(.separator())
        addServicesSection(menu)
        addClaudeSection(menu)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About McAwake…",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit McAwake",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // What the always-awake Mac is hosting — collapsed under ONE top-level
    // "Servers" item (hover to expand) so the first click stays clean.
    // The top-level title carries a ⚠️ badge when a watched item is down,
    // so trouble is still visible without expanding.
    func addServicesSection(_ menu: NSMenu) {
        let services = cachedServices
        let tunnels = cachedTunnels
        let watchDown = lastPortUp.values.contains(false) || lastTunnelUp.values.contains(false)

        let total = services.count + tunnels.count
        if total == 0 && !watchDown {
            addInfo(menu, "Servers — none detected")
            return
        }
        let top = NSMenuItem(
            title: watchDown ? "Servers (\(total)) ⚠️" : "Servers (\(total))",
            action: nil, keyEquivalent: "")
        let serversMenu = NSMenu()
        top.submenu = serversMenu
        menu.addItem(top)

        for s in services {
            let portsLabel = s.ports.map { ":\($0)" }.joined(separator: "  ")
            let item = NSMenuItem(title: "\(s.name)  \(portsLabel)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let info = NSMenuItem(title: "PID \(s.pid)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(.separator())
            for port in s.ports {
                let url = "http://localhost:\(port)"
                let open = NSMenuItem(title: "Open :\(port)",
                                      action: #selector(openServiceURL(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = url
                open.toolTip = url
                sub.addItem(open)
                let copy = NSMenuItem(title: "Copy :\(port)",
                                      action: #selector(copyServiceURL(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = url
                copy.toolTip = "Copy \(url)"
                sub.addItem(copy)
            }
            sub.addItem(.separator())
            for port in s.ports {
                let watched = watchedPorts.contains(port)
                let w = NSMenuItem(title: "Watch :\(port)",
                                   action: #selector(toggleWatchPort(_:)), keyEquivalent: "")
                w.target = self
                w.state = watched ? .on : .off
                w.toolTip = watched ? "Watching — click to stop down/up alerts"
                                    : "Alert when this port stops listening (checked every 60s)"
                w.representedObject = ["port": port, "label": s.name] as [String: Any]
                sub.addItem(w)
            }
            item.submenu = sub
            serversMenu.addItem(item)
        }

        for t in tunnels {
            let item = NSMenuItem(title: "\(t.name)  — tunnel", action: nil, keyEquivalent: "")
            item.toolTip = "Outbound tunnel — no local URL"
            let sub = NSMenu()
            let info = NSMenuItem(title: "PID \(t.pid)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(.separator())
            let watched = watchedTunnels.contains(t.name)
            let w = NSMenuItem(title: "Watch tunnel",
                               action: #selector(toggleWatchTunnel(_:)), keyEquivalent: "")
            w.target = self
            w.state = watched ? .on : .off
            w.toolTip = watched ? "Watching — click to stop down/up alerts"
                                : "Alert when the \(t.name) process stops (checked every 60s)"
            w.representedObject = t.name
            sub.addItem(w)
            item.submenu = sub
            serversMenu.addItem(item)
        }

        // Watched things that are DOWN disappear from live detection —
        // keep them visible (with their alert state) so they can still be
        // unwatched.
        let livePorts = Set(services.flatMap { $0.ports })
        for port in watchedPorts.subtracting(livePorts).sorted() {
            let label = portLabels[port] ?? "service"
            let item = NSMenuItem(title: "⚠️ \(label)  :\(port) — DOWN", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let info = NSMenuItem(title: "Nothing listening on :\(port) right now",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            let w = NSMenuItem(title: "Stop watching :\(port)",
                               action: #selector(toggleWatchPort(_:)), keyEquivalent: "")
            w.target = self
            w.representedObject = ["port": port, "label": label] as [String: Any]
            sub.addItem(w)
            item.submenu = sub
            serversMenu.addItem(item)
        }
        let liveTunnels = Set(tunnels.map { $0.name })
        for t in watchedTunnels.subtracting(liveTunnels).sorted() {
            let item = NSMenuItem(title: "⚠️ \(t)  — tunnel DOWN", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let w = NSMenuItem(title: "Stop watching \(t)",
                               action: #selector(toggleWatchTunnel(_:)), keyEquivalent: "")
            w.target = self
            w.representedObject = t
            sub.addItem(w)
            item.submenu = sub
            serversMenu.addItem(item)
        }
    }

    // Open Claude Code terminal sessions, labeled by the project folder
    // each one is working in. Hidden entirely when none are running.
    func addClaudeSection(_ menu: NSMenu) {
        let sessions = cachedSessions
        guard !sessions.isEmpty else { return }

        let top = NSMenuItem(title: "Claude (\(sessions.count))",
                             action: nil, keyEquivalent: "")
        let claudeMenu = NSMenu()
        top.submenu = claudeMenu
        menu.addItem(top)

        for s in sessions {
            let folder = s.cwd == "?" ? "unknown folder"
                : URL(fileURLWithPath: s.cwd).lastPathComponent
            let ttyShort = s.tty.replacingOccurrences(of: "ttys", with: "tty ")
            // Session NAME leads (it's what tells twins in the same folder
            // apart); folder gives context; ⚡ = currently busy.
            let title = s.name.map { "\($0)  (\(folder))" } ?? "\(folder)  (\(ttyShort))"
            let item = NSMenuItem(title: s.busy ? "⚡ \(title)" : title,
                                  action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let pathInfo = NSMenuItem(title: s.cwd, action: nil, keyEquivalent: "")
            pathInfo.isEnabled = false
            sub.addItem(pathInfo)
            let procInfo = NSMenuItem(
                title: "PID \(s.pid) · \(ttyShort) · running \(s.etime) · \(s.busy ? "busy" : "idle")",
                action: nil, keyEquivalent: "")
            procInfo.isEnabled = false
            sub.addItem(procInfo)
            sub.addItem(.separator())
            let jump = NSMenuItem(title: "Jump to terminal",
                                  action: #selector(jumpToClaudeSession(_:)), keyEquivalent: "")
            jump.target = self
            jump.toolTip = "Bring this session's Terminal/iTerm2 tab to the front"
            jump.representedObject = s.tty
            sub.addItem(jump)
            let reveal = NSMenuItem(title: "Reveal in Finder",
                                    action: #selector(revealClaudeFolder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = s.cwd
            sub.addItem(reveal)
            let copy = NSMenuItem(title: "Copy path",
                                  action: #selector(copyServiceURL(_:)), keyEquivalent: "")
            copy.target = self
            copy.toolTip = s.cwd
            copy.representedObject = s.cwd
            sub.addItem(copy)
            item.submenu = sub
            claudeMenu.addItem(item)
        }
    }

    // Bring the terminal window/tab that owns this session's tty to the
    // front. Terminal.app and iTerm2 both expose per-tab ttys to
    // AppleScript. Only apps that are ALREADY RUNNING are scripted —
    // `tell application` would otherwise launch them (the Amphetamine
    // relaunch lesson). First use triggers macOS's one-time
    // "McAwake wants to control Terminal" automation prompt.
    @objc func jumpToClaudeSession(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String else { return }
        let dev = "/dev/\(tty)"
        DispatchQueue.global().async { [weak self] in
            var focused = false
            if self?.appIsRunning("com.apple.Terminal") == true {
                let script = """
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(dev)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                      end if
                    end repeat
                  end repeat
                  return "notfound"
                end tell
                """
                focused = self?.runOsascript(script) == "ok"
            }
            if !focused, self?.appIsRunning("com.googlecode.iterm2") == true {
                let script = """
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with tb in tabs of w
                      repeat with s in sessions of tb
                        if tty of s is "\(dev)" then
                          select s
                          activate
                          return "ok"
                        end if
                      end repeat
                    end repeat
                  end repeat
                  return "notfound"
                end tell
                """
                focused = self?.runOsascript(script) == "ok"
            }
            if !focused {
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = "Couldn't find that terminal window"
                    a.informativeText = "No Terminal or iTerm2 tab owns \(dev). " +
                        "If the session runs inside another app (VS Code, etc.), " +
                        "McAwake can't bring it forward."
                    a.runModal()
                }
            }
        }
    }

    func appIsRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func runOsascript(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @objc func revealClaudeFolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String, path != "?" {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    @objc func openServiceURL(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func copyServiceURL(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
        }
    }

    func addInfo(_ menu: NSMenu, _ title: String, tooltip: String? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = tooltip
        menu.addItem(item)
    }

    func addMode(_ menu: NSMenu, _ title: String, _ sel: Selector, checked: Bool,
                 tooltip: String? = nil) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.toolTip = tooltip
        menu.addItem(item)
    }

    // MARK: Mode changes

    func installDaemonCmd(mode: String) -> String {
        guard let res = Bundle.main.resourcePath else { return "false" }
        return """
            set -e; \
            /bin/launchctl bootout system/\(daemonLabel) 2>/dev/null || true; \
            /usr/bin/install -d -o root -g wheel -m 755 \(shellQuote(daemonDirectory)) \(shellQuote(daemonStateDirectory)); \
            /usr/bin/install -o root -g wheel -m 755 \(shellQuote("\(res)/mcawake-auto.sh")) \(shellQuote(daemonScriptPath)); \
            /usr/bin/install -o root -g wheel -m 644 \(shellQuote("\(res)/\(daemonLabel).plist")) \(shellQuote(daemonPlistPath)); \
            /usr/libexec/PlistBuddy -c \(shellQuote("Set :ProgramArguments:3 \(getuid())")) \(shellQuote(daemonPlistPath)); \
            printf '%s\\n' \(shellQuote(mode)) > \(shellQuote(daemonModePath)); \
            /usr/sbin/chown root:wheel \(shellQuote(daemonModePath)); \
            /bin/chmod 644 \(shellQuote(daemonModePath)); \
            /bin/rm -f /usr/local/bin/mcawake-auto.sh; \
            /bin/launchctl bootstrap system \(shellQuote(daemonPlistPath))
            """
    }

    @objc func setAlwaysAwake() { setMode("always") }
    @objc func setSmartAuto() { setMode("auto") }
    @objc func setNormalSleep() { setMode("normal") }

    @objc func repairDaemon() {
        installDaemon(mode: installedDaemonMode() ?? "normal")
    }

    func setMode(_ mode: String) {
        lastModeChangeAt = Date()
        guard reusableDaemonConfigured() else {
            installDaemon(mode: mode)
            return
        }

        let fd = open(daemonControlPath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            showModeError("The daemon is not responding. Use Repair daemon in the menu.")
            refreshIcon()
            return
        }
        defer { close(fd) }
        let bytes = Array("\(mode)\n".utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            showModeError("The daemon could not receive the mode. Use Repair daemon in the menu.")
            refreshIcon()
            return
        }
        refreshAfterModeChange()
    }

    func installDaemon(mode: String) {
        lastModeChangeAt = Date()
        runAdmin(installDaemonCmd(mode: mode)) { [weak self] result in
            guard let self else { return }
            self.lastModeChangeAt = Date()
            switch result {
            case .success:
                self.refreshAfterModeChange()
            case .cancelled:
                self.refreshIcon()
            case .failed(let msg):
                self.showModeError(msg)
                self.refreshIcon()
            }
        }
    }

    func refreshAfterModeChange() {
        for delay in [0.3, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshIcon()
            }
        }
    }

    func showModeError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "McAwake couldn't apply that change"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Misc actions

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change the login item"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc func showAbout() {
        let a = NSAlert()
        a.messageText = "McAwake \(appVersion) 🦉"
        a.informativeText = """
            Keeps your Mac awake — even with the lid closed.

            Modes:
            🦉 Always Awake — the Mac never sleeps, plugged in or not. A \
            low-battery guard restores normal sleep below 15% on battery \
            (re-arms at 18% or on the charger), so a forgotten Mac can't \
            run itself flat.
            🔌 Smart Auto — awake whenever it's plugged in, normal sleep \
            on battery. Set-and-forget.
            💤 Normal Sleep — the macOS default.

            The menu also lists the local servers and tunnels this Mac is \
            hosting right now — click one to open or copy its localhost URL.

            The first mode change asks for your admin password to install \
            a root daemon. Later mode changes do not need the password. \
            The daemon only accepts the three modes and uses pmset disablesleep.
            """
        a.runModal()
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

// Debug/verification hook: dump service detection to stdout and exit.
// Used by humans and CI-adjacent smoke checks; not part of the app UI.
if CommandLine.arguments.contains("--print-services") {
    for s in detectLocalServices() {
        print("\(s.name)\tpid=\(s.pid)\tports=\(s.ports.map(String.init).joined(separator: ","))")
    }
    for t in detectTunnels() {
        print("\(t.name)\tpid=\(t.pid)\ttunnel")
    }
    exit(0)
}
if CommandLine.arguments.contains("--print-claude-sessions") {
    for s in detectClaudeSessions() {
        print("\(s.tty)\tpid=\(s.pid)\t\(s.name ?? "-")\t\(s.busy ? "busy" : "idle")\t\(s.etime)\t\(s.cwd)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
