import Foundation

/// Polls the latest GitHub release (drafts and prereleases are skipped by the API) and reports it
/// when it is newer than the running build. `UpdateInstaller` downloads and installs it.
///
/// Checks shortly after launch, then once a day. Network and decoding errors are logged and
/// otherwise ignored: the next check tries again.
@MainActor
final class UpdateChecker {
    struct Release: Equatable {
        var version: String
        /// The release page.
        var url: URL
        /// The `Silk-<version>.zip` asset, else the `.dmg`, if the release has one.
        var downloadURL: URL?
    }

    enum Outcome {
        case upToDate
        case available(Release)
        case failed(String)
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Jensderond/silk/releases/latest")!
    private static let launchDelay: TimeInterval = 10
    private static let interval: TimeInterval = 24 * 60 * 60

    /// The newer release, if any. Set by every successful check.
    private(set) var available: Release?
    /// Called on the main thread whenever `available` changes, and after every check that finds a
    /// release (so a download that failed is tried again).
    var onChange: (() -> Void)?
    private var timer: Timer?
    /// Non-nil while a request is in flight: who is waiting for it.
    private var waiting: [(Outcome) -> Void]?

    /// "0.1.3", or nil when running outside the app bundle (`swift run`), where there is nothing to update.
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func start() {
        guard Self.currentVersion != nil, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 60 * 60
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check(completion: ((Outcome) -> Void)? = nil) {
        guard let current = Self.currentVersion else {
            completion?(.failed("This build has no version to compare."))
            return
        }
        guard waiting == nil else {
            if let completion { waiting?.append(completion) }
            return
        }
        waiting = completion.map { [$0] } ?? []
        var request = URLRequest(url: Self.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Silk/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let outcome = Self.outcome(current: current, data: data, response: response, error: error)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let waiting = self.waiting ?? []
                    self.waiting = nil
                    switch outcome {
                        case .upToDate: self.setAvailable(nil)
                        case .available(let release): self.setAvailable(release)
                        case .failed(let reason): NSLog("Silk: update check failed: %@", reason)
                    }
                    waiting.forEach { $0(outcome) }
                }
            }
        }.resume()
    }

    private func setAvailable(_ release: Release?) {
        guard release != available || release != nil else { return }
        available = release
        onChange?()
    }

    private struct LatestRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        var tagName: String
        var htmlURL: URL
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private nonisolated static func outcome(current: String, data: Data?, response: URLResponse?, error: Error?) -> Outcome {
        if let error { return .failed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, let data else { return .failed("no response") }
        guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
        guard let latest = try? JSONDecoder().decode(LatestRelease.self, from: data) else { return .failed("unexpected response") }
        let version = latest.tagName.hasPrefix("v") ? String(latest.tagName.dropFirst()) : latest.tagName
        guard isVersion(version, newerThan: current) else { return .upToDate }
        let asset = ["zip", "dmg"].lazy.compactMap { ext in latest.assets.first { $0.name == "Silk-\(version).\(ext)" } }.first
        return .available(Release(version: version, url: latest.htmlURL, downloadURL: asset?.browserDownloadURL))
    }

    /// Compares dotted numeric versions ("0.1.10" > "0.1.9", "1.0" == "1.0.0"). Anything that isn't
    /// purely numeric is never newer, so an odd tag can't nag.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return parts.contains(nil) ? nil : parts.compactMap { $0 }
        }
        guard let new = parts(candidate), let old = parts(current) else { return false }
        for index in 0 ..< max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
