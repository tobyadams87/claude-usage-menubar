import Foundation

// Checks GitHub for a newer published release. Nothing is downloaded or installed by the app itself
// (it isn't signed or notarized): it only tells the user, and sends them to the download.

struct ReleaseInfo {
    let version: String      // "1.1.1" (leading "v" removed)
    let pageURL: URL         // the release page
    let downloadURL: URL?    // the attached .zip, if there is one
}

enum UpdateChecker {
    static let latestURL = URL(string: "https://api.github.com/repos/tobyadams87/claude-usage-menubar/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/tobyadams87/claude-usage-menubar/releases")!

    static var currentVersion: String {
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["CU_FAKE_VERSION"] { return fake }   // for testing only
        #endif
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // "1.10.0" is newer than "1.9.3": compare number by number, not as text.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = j["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
        return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                           pageURL: page, downloadURL: zip.flatMap(URL.init(string:)))
    }

    // Calls back on the main queue with the latest release, or nil if it couldn't be checked.
    static func fetchLatest(_ done: @escaping (ReleaseInfo?) -> Void) {
        var req = URLRequest(url: latestURL, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeUsage/\(currentVersion)", forHTTPHeaderField: "User-Agent")   // GitHub requires one
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let info = ok ? data.flatMap(parse) : nil
            DispatchQueue.main.async { done(info) }
        }.resume()
    }
}
