import AppKit
import CryptoKit
import Security
import SwiftUI

// MARK: - Pure logic (unit-tested)

struct ReleaseInfo: Equatable {
    let tag: String
    let version: String
    let notes: String
    let zipURL: URL
    let checksumURL: URL?
    let pageURL: URL
}

enum UpdateError: LocalizedError {
    case network(String), noRelease, badAsset(String), checksumMissing, checksumMismatch
    case invalidApp(String), cannotInstall(String)

    var errorDescription: String? {
        switch self {
        case .network(let m): return "Could not reach GitHub: \(m)"
        case .noRelease: return "No published release was found."
        case .badAsset(let m): return "The release is not usable: \(m)"
        case .checksumMissing: return "The release has no checksum file, so Sentinel will not install it."
        case .checksumMismatch: return "The download does not match its checksum. Nothing was installed."
        case .invalidApp(let m): return "The downloaded app failed a safety check: \(m)"
        case .cannotInstall(let m): return m
        }
    }
}

enum UpdateLogic {
    static let repository = "alfayedoficial/sentinel-mac"
    static let appIdentifier = "com.afapps.sentinel"
    static let zipName = "Sentinel.zip"
    static let checksumName = "Sentinel.zip.sha256"
    static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    static func versionParts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// `1.10.0` is newer than `1.9.0`; `1.1` equals `1.1.0`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = versionParts(candidate), b = versionParts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads are accepted only over HTTPS from GitHub's own hosts.
    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        guard let r = try? JSONDecoder().decode(APIRelease.self, from: data) else { throw UpdateError.noRelease }
        if r.draft == true || r.prerelease == true { throw UpdateError.noRelease }
        guard let zip = r.assets.first(where: { $0.name == zipName }), let zipURL = URL(string: zip.browser_download_url),
              isTrustedDownload(zipURL) else { throw UpdateError.badAsset("\(zipName) is missing or not on GitHub") }
        let sum = r.assets.first(where: { $0.name == checksumName }).flatMap { URL(string: $0.browser_download_url) }
        if let sum, !isTrustedDownload(sum) { throw UpdateError.badAsset("the checksum is not on GitHub") }
        guard let page = URL(string: r.html_url) else { throw UpdateError.badAsset("bad release page") }
        return ReleaseInfo(tag: r.tag_name, version: r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                           notes: r.body ?? "", zipURL: zipURL, checksumURL: sum, pageURL: page)
    }

    /// `shasum` output looks like `<64 hex>  Sentinel.zip`.
    static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy({ $0.isHexDigit }) ? hex : nil
    }

    static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks that a downloaded app is really Sentinel, is validly signed and is newer. Returns its version.
    @discardableResult
    static func validateBundle(_ url: URL, newerThan current: String, identifier: String = appIdentifier) throws -> String {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier else {
            throw UpdateError.invalidApp("it is not Sentinel")
        }
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            throw UpdateError.invalidApp("it has no version")
        }
        guard isNewer(version, than: current) else { throw UpdateError.invalidApp("version \(version) is not newer than \(current)") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.invalidApp("cannot read its signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw UpdateError.invalidApp("its signature is not valid") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], (dict[kSecCodeInfoIdentifier as String] as? String) == identifier else {
            throw UpdateError.invalidApp("its signing identity is not Sentinel's")
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/Sentinel").path) else {
            throw UpdateError.invalidApp("the program is missing")
        }
        return version
    }

    /// Puts `new` where `old` is. The old copy is kept in `backupDir` so it can be restored; if anything fails it is put back.
    static func swap(new: URL, over old: URL, backupDir: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: backupDir)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let backup = backupDir.appendingPathComponent(old.lastPathComponent)
        do { try fm.moveItem(at: old, to: backup) } catch { throw UpdateError.cannotInstall("Sentinel cannot replace itself here (\(error.localizedDescription)). Download the update manually.") }
        do { try fm.moveItem(at: new, to: old) } catch {
            try? fm.moveItem(at: backup, to: old)
            throw UpdateError.cannotInstall("The update could not be put in place, so the old version was kept.")
        }
    }
}

// MARK: - Updater (what the UI reads)

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case working(String)
        case failed(String)          // the check could not run (offline, rate limit)
        case installFailed(String)   // a download or safety check stopped an install
    }

    @Published var state: State = .idle
    @Published var lastChecked: Date?

    /// Replaceable in tests so no real network is needed.
    var fetch: (URLRequest) async throws -> Data = { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.network("HTTP \(http.statusCode)")
        }
        return data
    }
    var currentVersion = AppInfo.version
    private var timer: Timer?

    static var autoCheck: Bool { (UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool) ?? true }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in if Updater.autoCheck { await self?.check() } }
        }
        timer?.tolerance = 3600
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)      // let the app settle first
            if Updater.autoCheck { await check() }
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("Sentinel/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return r
    }

    func check() async {
        if Demo.enabled { return }
        if case .working = state { return }
        state = .checking
        do {
            let data = try await fetch(request(UpdateLogic.latestReleaseAPI))
            let info = try UpdateLogic.parseRelease(data)
            lastChecked = Date()
            state = UpdateLogic.isNewer(info.version, than: currentVersion) ? .available(info) : .upToDate
        } catch UpdateError.noRelease {
            lastChecked = Date(); state = .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Download, verify, replace and restart.
    func install() async {
        guard case .available(let info) = state else { return }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sentinel-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            state = .working("Downloading \(info.version)…")
            guard let sumURL = info.checksumURL else { throw UpdateError.checksumMissing }
            let (tmp, _) = try await URLSession.shared.download(from: info.zipURL)
            let zip = work.appendingPathComponent(UpdateLogic.zipName)
            try fm.moveItem(at: tmp, to: zip)

            state = .working("Checking the download…")
            let sumText = String(data: try await fetch(request(sumURL)), encoding: .utf8) ?? ""
            guard let expected = UpdateLogic.parseChecksum(sumText) else { throw UpdateError.checksumMissing }
            guard try UpdateLogic.sha256(of: zip) == expected else { throw UpdateError.checksumMismatch }

            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            guard Updater.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else { throw UpdateError.badAsset("the zip could not be opened") }
            let newApp = unpacked.appendingPathComponent("Sentinel.app")
            _ = try UpdateLogic.validateBundle(newApp, newerThan: currentVersion)
            _ = removexattr(newApp.path, "com.apple.quarantine", XATTR_NOFOLLOW)

            let target = Bundle.main.bundleURL
            guard target.pathExtension == "app", fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError.cannotInstall("Sentinel cannot update itself in this folder. Download the update from the website.")
            }
            state = .working("Installing…")
            let backup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sentinel/previous", isDirectory: true)
            try UpdateLogic.swap(new: newApp, over: target, backupDir: backup)

            state = .working("Restarting…")
            UserDefaults.standard.set(info.version, forKey: "justUpdatedTo")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", target.path]
            try p.run()
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        } catch {
            state = .installFailed(error.localizedDescription)
        }
    }

    private static func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}

// MARK: - Views

struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared
    @State private var showNotes = false

    var body: some View {
        Group {
            switch updater.state {
            case .available(let info):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sentinel \(info.version) is available").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            Text("You have \(updater.currentVersion). Updates install in seconds.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Button("Update") { Task { await updater.install() } }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.accentDeep)
                            .padding(.horizontal, 14).padding(.vertical, 6).background(Capsule().fill(.white))
                    }
                    HStack(spacing: 14) {
                        Button { withAnimation(.spring(duration: 0.3)) { showNotes.toggle() } } label: {
                            Text(showNotes ? "Hide what's new" : "What's new").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        }.buttonStyle(.plain)
                        Link("Release page", destination: info.pageURL).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    }
                    if showNotes {
                        Text(info.notes.isEmpty ? "No notes." : String(info.notes.prefix(600)))
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.brand))
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            case .working(let text):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .transition(.opacity)
            case .installFailed(let msg):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(msg).font(.system(size: 11)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try again") { Task { await updater.check() } }.controlSize(.small)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.12)))
            default:
                EmptyView()
            }
        }
        .animation(.spring(duration: 0.35), value: updater.state)
    }
}

struct UpdatesCard: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage("autoUpdateCheck") private var auto = true

    var body: some View {
        Card {
            Toggle("Check for updates automatically", isOn: $auto).toggleStyle(CheckToggleStyle())
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(status).font(.system(size: 12, weight: .semibold))
                    Text("Version \(updater.currentVersion) · checks GitHub Releases only").font(.system(size: 10.5)).foregroundStyle(Theme.t2)
                }
                Spacer()
                switch updater.state {
                case .checking, .working: ProgressView().controlSize(.small)
                case .available: Button("Update") { Task { await updater.install() } }.buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.small)
                default: Button("Check now") { Task { await updater.check() } }.controlSize(.small)
                }
            }
            Text("The only network request Sentinel makes is to api.github.com, to read the latest release. No personal data is sent.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.t2)
        }
    }

    private var status: String {
        switch updater.state {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "You have the latest version"
        case .available(let i): return "Version \(i.version) is available"
        case .working(let t): return t
        case .failed: return "Could not check for updates"
        case .installFailed: return "The update was not installed"
        }
    }
}
