import AppKit
import Combine
import Darwin
import Security
import SwiftUI

// MARK: - Rules (pure logic, unit-tested)

enum SignState: Equatable {
    case apple, developer, adhoc, unsigned, unknown
    var label: String {
        switch self {
        case .apple: "Apple"
        case .developer: "Signed developer"
        case .adhoc: "Locally signed"
        case .unsigned: "Unsigned"
        case .unknown: "Unknown"
        }
    }
}

enum Severity: Int, Comparable {
    case medium = 1, high = 2
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct ProcInfo {
    var pid: Int32 = 0
    var path: String
    var args: [String] = []
    var cpu: Double = 0
    var sustainedScans: Int = 0
    var sign: SignState = .unknown
    var exists: Bool = true
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct Finding: Equatable {
    var severity: Severity
    var reasons: [String]
}

enum ThreatRules {
    static let minerNames: [String] = [
        "xmrig", "xmr-stak", "minerd", "cpuminer", "ethminer", "cgminer", "bfgminer", "nbminer", "t-rex",
        "lolminer", "phoenixminer", "gminer", "ccminer", "teamredminer", "srbminer", "kdevtmpfsi", "kinsing",
        "minergate", "nicehash", "xmrigdaemon", "randomx", "cryptonight"
    ]
    static let miningArgs: [String] = [
        "stratum+tcp://", "stratum+ssl://", "stratum2+tcp://", "--donate-level", "cryptonight", "randomx", "rx/0",
        "minergate", "nicehash", "moneroocean", "supportxmr", "nanopool.org", "2miners.com", "f2pool.com", "hashvault.pro"
    ]
    /// Places legitimate programs almost never run from.
    static let suspiciousDirs: [String] = ["/tmp/", "/private/tmp/", "/private/var/tmp/", "/var/tmp/", "/users/shared/", "/dev/shm/"]
    /// Hidden folders that normal developer tools use.
    static let knownHidden: Set<String> = [
        ".gradle", ".npm", ".cache", ".local", ".nvm", ".cargo", ".rustup", ".konan", ".android", ".m2", ".pub-cache",
        ".maestro", ".config", ".docker", ".pyenv", ".sdkman", ".bun", ".volta", ".fnm", ".deno", ".asdf", ".kube",
        ".vscode", ".cocoapods", ".trash"
    ]
    /// Extra hidden folders you trust, set locally: `defaults write com.afapps.sentinel threatKnownHidden -array .mytool`
    static var extraKnownHidden: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: "threatKnownHidden") ?? []).map { $0.lowercased() })
    }
    static let trustedApplePrefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/Library/Apple/"]
    static let trustedDevPrefixes = ["/Applications/", "/opt/homebrew/", "/usr/local/", "/Library/Developer/", "/Library/Java/"]
    static let trustedDevFragments = ["/Library/Java/", "/.gradle/", "/.konan/", "/.sdkman/", "/Xcode.app/", "/.cargo/", "/.nvm/", "/.rustup/"]

    static func isApplePath(_ p: String) -> Bool { trustedApplePrefixes.contains { p.hasPrefix($0) } }

    static func inSuspiciousLocation(_ path: String) -> Bool {
        let lower = path.lowercased()
        if suspiciousDirs.contains(where: { lower.hasPrefix($0) }) { return true }
        // a hidden folder directly inside the home folder that is not a known developer folder
        let home = NSHomeDirectory().lowercased() + "/"
        if lower.hasPrefix(home) {
            let first = lower.dropFirst(home.count).split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix(".") && !knownHidden.contains(first) && !extraKnownHidden.contains(first) { return true }
        }
        return false
    }

    static func isTrustedDevLocation(_ path: String) -> Bool {
        trustedDevPrefixes.contains { path.hasPrefix($0) } || trustedDevFragments.contains { path.contains($0) }
    }

    /// Shells and scripting runtimes. Their command line can contain anything (a developer typing `grep stratum`),
    /// so text found only in their arguments counts only when they are also burning CPU like a miner would.
    static let interpreters = ["sh", "bash", "zsh", "dash", "ksh", "fish", "python", "perl", "ruby", "node", "osascript", "pwsh", "php", "lua"]

    static func isInterpreter(_ path: String) -> Bool {
        let n = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return interpreters.contains { n == $0 || (n.hasPrefix($0) && n.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." }) }
    }

    static func nameHit(path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if let m = minerNames.first(where: { name.contains($0) }) { return "Its name matches the cryptocurrency miner “\(m)”." }
        return nil
    }

    static func minerHit(path: String, args: [String]) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if let m = minerNames.first(where: { name.contains($0) }) { return "Its name matches the cryptocurrency miner “\(m)”." }
        // What an interpreter is running: `sh xmrig.sh`, `sh -c "xmrig …"`. Only the first words, so `grep xmrig` stays quiet.
        var launched: [String] = []
        if args.count > 1 {
            if args[1] == "-c", args.count > 2 { launched.append(String(args[2].split(separator: " ").first ?? "")) }
            else if !args[1].hasPrefix("-") { launched.append(args[1]) }
        }
        for item in launched {
            let base = URL(fileURLWithPath: item).lastPathComponent.lowercased()
            if let m = minerNames.first(where: { base.contains($0) }) { return "It is running a program or script named “\(m)”, a cryptocurrency miner." }
        }
        let joined = args.joined(separator: " ").lowercased()
        if let a = miningArgs.first(where: { joined.contains($0) }) { return "Its arguments contain “\(a)”, which is used to connect to mining pools." }
        return nil
    }

    static func evaluate(_ p: ProcInfo) -> Finding? {
        var reasons: [String] = []
        var severity = Severity.medium

        // Checked first on purpose: a miner can hide inside a trusted-looking folder.
        if let hit = nameHit(path: p.path) {
            reasons.append(hit); severity = .high
        } else if let hit = minerHit(path: p.path, args: p.args) {
            // text in an interpreter's command line is only suspicious if it is actually working hard
            if !isInterpreter(p.path) || p.cpu >= 25 { reasons.append(hit); severity = .high }
        }

        if !p.exists && !p.path.isEmpty && !isApplePath(p.path) {
            reasons.append("It is running from a file that was deleted, a common trick of malware.")
            severity = .high
        }
        if !reasons.isEmpty { return Finding(severity: severity, reasons: reasons) }

        if isApplePath(p.path) && p.sign == .apple { return nil }

        let suspiciousPlace = inSuspiciousLocation(p.path)
        let trustedDev = isTrustedDevLocation(p.path)
        let identified = p.sign == .developer || p.sign == .apple

        if p.cpu >= 70 && p.sustainedScans >= 3 && !identified && !trustedDev {
            reasons.append("Using \(Int(p.cpu))% CPU for a long time, from an unidentified program.")
        }
        if suspiciousPlace && (p.sign == .unsigned || p.sign == .adhoc || p.sign == .unknown) && p.cpu >= 20 && !trustedDev {
            reasons.append("An unsigned program is running from a temporary or hidden folder (\(URL(fileURLWithPath: p.path).deletingLastPathComponent().path)).")
        }
        return reasons.isEmpty ? nil : Finding(severity: .medium, reasons: reasons)
    }

    /// For launch agents/daemons: does the thing they start look like malware persistence?
    static func suspiciousLaunchItem(program: String?, arguments: [String]) -> String? {
        let all = ([program].compactMap { $0 } + arguments).joined(separator: " ")
        let lower = all.lowercased()
        if let hit = minerHit(path: program ?? "", args: arguments) { return hit }
        if let p = program, inSuspiciousLocation(p) { return "Starts a program from a temporary or hidden folder." }
        let tricks = ["curl ", "wget ", "| sh", "|sh", "| bash", "|bash", "base64 -d", "base64 --decode", "nohup ", "/tmp/", "/private/tmp/", "eval $(", "python -c", "perl -e"]
        if let t = tricks.first(where: { lower.contains($0) }) { return "Runs a command that uses “\(t.trimmingCharacters(in: .whitespaces))”, typical of programs that download and run code." }
        return nil
    }
}

// MARK: - Scanner (background queue, never on the main thread)

struct Threat: Identifiable, Equatable {
    var id: String
    var pid: Int32?
    var pids: [Int32]
    var name: String
    var path: String
    var cpu: Double
    var severity: Severity
    var reasons: [String]
    var args: String
    var sign: SignState
    var plistPath: String?
    var isPersistence: Bool { plistPath != nil }
}

struct OutsideProc: Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
    var cpu: Double
    var sign: SignState
}

final class ThreatScanner: @unchecked Sendable {
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var sustained: [Int32: Int] = [:]
    private var signCache: [String: SignState] = [:]
    private var timebase = mach_timebase_info_data_t()

    init() { mach_timebase_info(&timebase) }

    struct Result { var threats: [Threat]; var outside: [OutsideProc] }

    func scan(allowed: Set<String>) -> Result {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let dt = prevTime == 0 ? 0 : Double(nowNs - prevTime)
        let me = getpid()

        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return Result(threats: [], outside: []) }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        var buf = [CChar](repeating: 0, count: 4096)

        var newPrev: [Int32: UInt64] = [:]
        var newSustained: [Int32: Int] = [:]
        var byPath: [String: Threat] = [:]
        var outside: [String: OutsideProc] = [:]

        for pid in pids.prefix(Int(got)) where pid > 1 && pid != me {
            let len = proc_pidpath(pid, &buf, 4096)
            guard len > 0 else { continue }
            let path = String(cString: buf)

            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            var cpu = 0.0
            if ok == 0 {
                let ns = (ru.ri_user_time &+ ru.ri_system_time) &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
                newPrev[pid] = ns
                if dt > 0, let p = prevCPU[pid], ns >= p { cpu = Double(ns - p) / dt * 100 }
            }
            newSustained[pid] = cpu >= 50 ? (sustained[pid] ?? 0) + 1 : 0

            if allowed.contains(path) { continue }
            let applePath = ThreatRules.isApplePath(path)
            let name = URL(fileURLWithPath: path).lastPathComponent
            let exists = FileManager.default.fileExists(atPath: path)

            // Arguments are cheap to read, so every process gets checked (this catches a renamed miner that idles).
            // The signature check is slower, so it only runs when it can change the verdict.
            let args = readArgs(pid) ?? []
            let nameHit = ThreatRules.minerNames.contains { name.lowercased().contains($0) }
            let needsSign = nameHit || !exists || cpu >= 20 || ThreatRules.inSuspiciousLocation(path)
            let sign = needsSign ? signState(path) : (signCache[path] ?? .unknown)
            let inBundle = path.contains(".app/")
            if !inBundle && !applePath { outside[path] = merge(outside[path], pid: pid, name: name, path: path, cpu: cpu, sign: sign) }
            let info = ProcInfo(pid: pid, path: path, args: args, cpu: cpu, sustainedScans: newSustained[pid] ?? 0, sign: sign, exists: exists)
            guard let f = ThreatRules.evaluate(info) else { continue }
            if var t = byPath[path] {
                t.pids.append(pid); t.cpu += cpu
                byPath[path] = t
            } else {
                byPath[path] = Threat(id: "proc:" + path, pid: pid, pids: [pid], name: name, path: path, cpu: cpu,
                                      severity: f.severity, reasons: f.reasons,
                                      args: args.dropFirst().joined(separator: " "), sign: sign, plistPath: nil)
            }
        }
        prevCPU = newPrev
        sustained = newSustained
        prevTime = nowNs

        // sign state for the "outside apps" list (cached, so only new paths cost anything)
        var list = Array(outside.values).sorted { $0.cpu > $1.cpu }.prefix(8).map { o -> OutsideProc in
            var o = o
            if o.sign == .unknown { o.sign = signState(o.path) }
            return o
        }
        list.sort { $0.cpu > $1.cpu }
        return Result(threats: byPath.values.sorted { ($0.severity, $0.cpu) > ($1.severity, $1.cpu) }, outside: list)
    }

    private func merge(_ old: OutsideProc?, pid: Int32, name: String, path: String, cpu: Double, sign: SignState = .unknown) -> OutsideProc {
        var o = old ?? OutsideProc(id: path, name: name, path: path, cpu: 0, sign: sign)
        o.cpu += cpu
        if sign != .unknown { o.sign = sign }
        return o
    }

    func signState(_ path: String) -> SignState {
        if let c = signCache[path] { return c }
        let state = computeSign(path)
        signCache[path] = state
        return state
    }

    private func computeSign(_ path: String) -> SignState {
        if ThreatRules.isApplePath(path) { return .apple }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return .unknown }
        let valid = SecStaticCodeCheckValidity(code, [], nil)
        if valid == errSecCSUnsigned { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unknown }
        if valid != errSecSuccess { return .unsigned }   // signature present but broken: treat as untrusted
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty { return .developer }
        if let id = dict[kSecCodeInfoIdentifier as String] as? String, id.hasPrefix("com.apple.") { return .apple }
        return .adhoc
    }

    /// Command-line arguments of a process of the same user (nil for other users' processes).
    func readArgs(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        var argc: Int32 = 0
        memcpy(&argc, buf, 4)
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }       // executable path
        while i < size && buf[i] == 0 { i += 1 }       // padding
        var out: [String] = []
        var count = 0
        while i < size && count < Int(argc) && count < 64 {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
            count += 1
        }
        return out
    }
}

// MARK: - Watcher (what the UI reads)

@MainActor
final class ThreatWatch: ObservableObject {
    static let shared = ThreatWatch()

    @Published var threats: [Threat] = []
    @Published var outside: [OutsideProc] = []
    @Published var lastScan: Date?
    @Published var message: String?

    var onNewThreats: (([Threat]) -> Void)?

    private let scanner = ThreatScanner()
    private let queue = DispatchQueue(label: "sentinel.threats", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var notified: [String: Date] = [:]
    private var tick = 0

    var uiVisible = false { didSet { if uiVisible != oldValue { schedule(); if uiVisible { scanNow() } } } }

    var allowed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "threatAllowed") ?? []) }

    func start() { schedule(); scanNow() }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: uiVisible ? 5 : 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanNow() }
        }
        timer?.tolerance = 1
    }

    func scanNow() {
        guard !Demo.enabled else { return }
        guard !busy else { return }
        busy = true
        tick += 1
        let allow = allowed
        let checkPersistence = tick % 30 == 1            // launch items rarely change: about every 5 minutes
        queue.async { [scanner, weak self] in
            var result = scanner.scan(allowed: allow)
            if checkPersistence {
                for item in StartupManager.scanAgents() {
                    guard let why = item.suspicious, !allow.contains(item.path ?? item.id) else { continue }
                    result.threats.append(Threat(id: "launch:" + item.id, pid: nil, pids: [], name: item.name, path: item.program ?? item.path ?? "",
                                                 cpu: 0, severity: .medium, reasons: [why], args: "", sign: .unknown, plistPath: item.path))
                }
            }
            Task { @MainActor in
                self?.apply(result, includesPersistence: checkPersistence)
                self?.busy = false
            }
        }
    }

    private func apply(_ r: ThreatScanner.Result, includesPersistence: Bool) {
        lastScan = Date()
        if r.outside != outside { outside = r.outside }
        var merged = r.threats
        if !includesPersistence { merged += threats.filter { $0.isPersistence } }   // keep until the next full check
        merged.sort { ($0.severity, $0.cpu) > ($1.severity, $1.cpu) }
        if merged != threats { withAnimation(.spring(duration: 0.35)) { threats = merged } }
        Monitor.shared.bar.threat = !merged.isEmpty

        let now = Date()
        let fresh = merged.filter { t in
            if let last = notified[t.id], now.timeIntervalSince(last) < (t.severity == .high ? 300 : 1800) { return false }
            return true
        }
        if !fresh.isEmpty {
            for t in fresh { notified[t.id] = now }
            onNewThreats?(fresh)
        }
    }

    // MARK: actions

    /// Stops every process running that program. Falls back to the admin prompt for processes owned by root.
    func stop(_ t: Threat, trashFile: Bool) {
        let pids = t.pids
        let path = t.path
        Task.detached { [weak self] in
            var needsAdmin: [Int32] = []
            for pid in pids {
                if kill(pid, SIGKILL) != 0 && errno == EPERM { needsAdmin.append(pid) }
            }
            if !needsAdmin.isEmpty { _ = runAdmin("kill -9 " + needsAdmin.map(String.init).joined(separator: " ")) }
            var note = "Stopped \(t.name)."
            if trashFile && FileManager.default.fileExists(atPath: path) {
                note += Trasher.trash(URL(fileURLWithPath: path), kind: "Suspicious program") ? " File moved to the Trash." : " The file could not be moved."
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await self?.afterStop(t, note: note)
        }
    }

    private func afterStop(_ t: Threat, note: String) {
        withAnimation(.spring(duration: 0.35)) { threats.removeAll { $0.id == t.id } }
        message = note
        Monitor.shared.bar.threat = !threats.isEmpty
        scanNow()
    }

    func allow(_ t: Threat) {
        var list = UserDefaults.standard.stringArray(forKey: "threatAllowed") ?? []
        let key = t.plistPath ?? t.path
        if !list.contains(key) { list.append(key) }
        UserDefaults.standard.set(list, forKey: "threatAllowed")
        withAnimation(.spring(duration: 0.35)) { threats.removeAll { $0.id == t.id } }
        Monitor.shared.bar.threat = !threats.isEmpty
    }

    func disallow(_ path: String) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: "threatAllowed") ?? []).filter { $0 != path }, forKey: "threatAllowed")
        objectWillChange.send()
    }

    /// Switches off the launch item that keeps starting the program.
    func turnOffLaunchItem(_ t: Threat) {
        guard let plist = t.plistPath else { return }
        let hub = Hub.shared.startup
        let kind: StartupKind = plist.hasPrefix("/Library/LaunchDaemons") ? .systemDaemon : plist.hasPrefix("/Library/") ? .systemAgent : .userAgent
        let label = (NSDictionary(contentsOfFile: plist)?["Label"] as? String) ?? URL(fileURLWithPath: plist).deletingPathExtension().lastPathComponent
        hub.disable(StartupItem(id: plist, kind: kind, label: label, name: t.name, path: plist, program: t.path, running: false, broken: false, suspicious: t.reasons.first))
        withAnimation(.spring(duration: 0.35)) { threats.removeAll { $0.id == t.id } }
        Monitor.shared.bar.threat = !threats.isEmpty
    }
}

// MARK: - Popup

final class ThreatModel: ObservableObject {
    @Published var items: [Threat] = []
}

@MainActor
final class ThreatPresenter {
    static let shared = ThreatPresenter()
    private let model = ThreatModel()
    private var panel: FloatingPanel?
    private var host: NSHostingView<ThreatAlertView>?
    private var bag = Set<AnyCancellable>()

    func show(_ new: [Threat]) {
        for n in new where !model.items.contains(where: { $0.id == n.id }) {
            withAnimation(.spring(duration: 0.45)) { model.items.append(n) }
        }
        if panel == nil { build() }
        layout(animated: panel?.isVisible == false)
        NSSound(named: "Basso")?.play()
    }

    private func build() {
        let host = NSHostingView(rootView: ThreatAlertView(model: model, onClose: { [weak self] in self?.close() }))
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host
        panel = p
        self.host = host
        model.$items.receive(on: DispatchQueue.main).sink { [weak self] items in
            if items.isEmpty { self?.close() } else { self?.layout(animated: false) }
        }.store(in: &bag)
    }

    private func layout(animated: Bool) {
        guard let panel, let host, let screen = NSScreen.main else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let vf = screen.visibleFrame
        let target = NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 10, width: size.width, height: size.height)
        if animated {
            panel.setFrame(target.offsetBy(dx: 0, dy: 30), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true, animate: panel.isVisible)
            panel.orderFrontRegardless()
        }
    }

    func close() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            Task { @MainActor in self?.model.items.removeAll() }
        })
    }
}

struct ThreatAlertView: View {
    @ObservedObject var model: ThreatModel
    var onClose: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.danger.opacity(0.2)).frame(width: 44, height: 44).scaleEffect(pulse ? 1.15 : 1)
                    Image(systemName: "exclamationmark.shield.fill").font(.system(size: 22)).foregroundStyle(Theme.danger)
                }
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.items.count == 1 ? "Suspicious program running" : "\(model.items.count) suspicious programs running")
                        .font(.system(size: 15, weight: .bold))
                    Text("Running in the background, outside your normal apps").font(.system(size: 11.5)).foregroundStyle(Theme.t2)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.t2.opacity(0.6)) }
                    .buttonStyle(.plain)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.items) { t in
                        ThreatRow(t: t) { withAnimation(.spring(duration: 0.4)) { model.items.removeAll { $0.id == t.id } } }
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                }
            }
            .frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.danger.opacity(0.7), lineWidth: 1.5))
    }
}

struct ThreatRow: View {
    let t: Threat
    var onHandled: () -> Void
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(t.severity == .high ? "HIGH RISK" : "SUSPICIOUS").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(t.severity == .high ? Theme.danger : Theme.warning))
                Text(t.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Spacer()
                if t.cpu >= 1 { Chip(text: "\(Int(t.cpu))%", icon: "cpu") }
            }
            ForEach(t.reasons, id: \.self) { r in
                Text(r).font(.system(size: 11.5)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
            }
            Button { withAnimation(.spring(duration: 0.3)) { details.toggle() } } label: {
                Label(details ? "Hide details" : "Details", systemImage: details ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.link)
            }.buttonStyle(.plain)
            if details {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    if !t.args.isEmpty { Text(t.args).font(.system(size: 10, design: .monospaced)).lineLimit(3).textSelection(.enabled) }
                    Text("Signature: \(t.sign.label)").font(.system(size: 10)).foregroundStyle(Theme.t2)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 8) {
                if t.isPersistence {
                    Button { ThreatWatch.shared.turnOffLaunchItem(t); onHandled() } label: { Label("Turn off", systemImage: "power") }
                        .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.small)
                } else {
                    Button { ThreatWatch.shared.stop(t, trashFile: false); onHandled() } label: { Label("Stop now", systemImage: "hand.raised.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.small)
                    Button { ThreatWatch.shared.stop(t, trashFile: true); onHandled() } label: { Label("Stop & move to Trash", systemImage: "trash") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Menu("It's safe") {
                    Button("Always allow this program") { ThreatWatch.shared.allow(t); onHandled() }
                    Button("Remind me later") { onHandled() }
                }.menuStyle(.borderlessButton).controlSize(.small).fixedSize()
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.danger.opacity(0.1)))
    }
}

// MARK: - Tools screen

struct ThreatWatchView: View {
    @ObservedObject private var w = ThreatWatch.shared
    @State private var pendingStop: Threat?

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: w.threats.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 30)).foregroundStyle(w.threats.isEmpty ? Theme.success : Theme.danger)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.threats.isEmpty ? "No suspicious programs" : "\(w.threats.count) suspicious program(s)")
                                .font(.system(size: 14, weight: .bold))
                            Text(w.lastScan.map { "Last check " + $0.formatted(.relative(presentation: .numeric)) } ?? "Checking…")
                                .font(.system(size: 11)).foregroundStyle(Theme.t2)
                        }
                        Spacer()
                        Button("Scan now") { w.scanNow() }.controlSize(.small).buttonStyle(.bordered)
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill((w.threats.isEmpty ? Theme.success : Theme.danger).opacity(0.12)))

                    if let m = w.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.success).frame(maxWidth: .infinity, alignment: .leading) }

                    ForEach(w.threats) { t in ThreatRow(t: t) {}.transition(.scale(scale: 0.95).combined(with: .opacity)) }

                    Text("Sentinel checks every few seconds for crypto miners, programs running from deleted files, unsigned programs using heavy CPU from temporary folders, and launch items that download and run code.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.t2).frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Background programs outside your apps").font(.system(size: 12, weight: .semibold))
                        if w.outside.isEmpty { Text("None found").font(.system(size: 11)).foregroundStyle(Theme.t2) }
                        ForEach(w.outside) { o in
                            HStack(spacing: 8) {
                                Circle().fill(color(o.sign)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(o.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text(o.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 9.5)).foregroundStyle(Theme.t2).lineLimit(1)
                                }
                                Spacer()
                                Text(o.sign.label).font(.system(size: 10)).foregroundStyle(Theme.t2)
                                Text("\(Int(o.cpu))%").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))

                    if !w.allowed.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Allowed by you").font(.system(size: 12, weight: .semibold))
                            ForEach(Array(w.allowed).sorted(), id: \.self) { p in
                                HStack {
                                    Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10.5)).lineLimit(1)
                                    Spacer()
                                    Button("Remove") { w.disallow(p) }.controlSize(.small)
                                }
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .animation(.spring(duration: 0.35), value: w.threats)
        .onAppear { w.uiVisible = true; w.scanNow() }
        .onDisappear { w.uiVisible = false }
    }

    private func color(_ s: SignState) -> Color {
        switch s {
        case .apple, .developer: Theme.success
        case .adhoc: Theme.warning
        case .unsigned, .unknown: Theme.danger
        }
    }
}
