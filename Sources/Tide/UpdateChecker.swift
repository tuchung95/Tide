import Foundation

/// Checks the GitHub Releases API for a newer published version than the
/// one currently running (`CFBundleShortVersionString`). Releases are
/// published automatically by Scripts/build_app.sh.
enum UpdateChecker {

    struct UpdateInfo {
        var version: String
        var downloadURL: URL
    }

    private static let repo = "tuchung95/Tide"

    /// Calls back on an arbitrary background thread with update info if a
    /// newer version with a downloadable .zip asset is available, or nil if
    /// already up to date / the check failed for any reason (offline, rate
    /// limited, no releases yet, etc — all treated the same: no update).
    static func checkForUpdate(completion: @escaping (UpdateInfo?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let downloadURLString = zipAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString)
            else {
                completion(nil)
                return
            }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard Self.isNewer(latestVersion, than: currentVersion) else {
                completion(nil)
                return
            }

            completion(UpdateInfo(version: latestVersion, downloadURL: downloadURL))
        }.resume()
    }

    /// Compares dotted version strings numerically component by component
    /// (so "1.10.0" > "1.9.0", unlike a plain string comparison).
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(aParts.count, bParts.count) {
            let aValue = index < aParts.count ? aParts[index] : 0
            let bValue = index < bParts.count ? bParts[index] : 0
            if aValue != bValue { return aValue > bValue }
        }
        return false
    }
}
