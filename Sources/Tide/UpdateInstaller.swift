import AppKit
import Security

/// Downloads a release .zip, extracts it, and swaps it in for the currently
/// running /Applications/Tide.app — then relaunches. Because this process
/// can't overwrite its own running executable, the actual swap is done by a
/// short detached shell script spawned just before this process quits; the
/// shell keeps running after the parent (this app) exits.
enum UpdateInstaller {

    enum InstallError: LocalizedError {
        case downloadFailed
        case extractFailed
        case appNotFoundInArchive
        case signedByDifferentCertificate

        var errorDescription: String? {
            switch self {
            case .downloadFailed:
                return "The update could not be downloaded."
            case .extractFailed:
                return "The downloaded update could not be unpacked."
            case .appNotFoundInArchive:
                return "The downloaded update does not contain Tide.app."
            case .signedByDifferentCertificate:
                return "The downloaded update is signed by a different certificate than the installed Tide, "
                    + "so macOS would treat it as a new app and revoke the Screen Recording and Accessibility "
                    + "permissions you've already granted. The update was not installed — download it from "
                    + "GitHub Releases and replace /Applications/Tide.app by hand if you still want it."
            }
        }
    }

    private static let installedAppPath = "/Applications/Tide.app"

    static func downloadAndInstall(from url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { location, _, error in
            guard let location, error == nil else {
                DispatchQueue.main.async { completion(.failure(error ?? InstallError.downloadFailed)) }
                return
            }

            do {
                let appPath = try Self.extract(downloadedFileAt: location)
                try Self.verifySameSigner(asRunningApp: appPath)
                Self.relaunch(withNewAppAt: appPath)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
    }

    private static func extract(downloadedFileAt location: URL) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let zipPath = tempDir.appendingPathComponent("update.zip")
        let extractDir = tempDir.appendingPathComponent("extracted")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: location, to: zipPath)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipPath.path, extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw InstallError.extractFailed
        }

        guard let appBundle = try FileManager.default
            .contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else {
            throw InstallError.appNotFoundInArchive
        }

        return appBundle.path
    }

    /// Refuses an update that isn't signed by the same certificate as the
    /// running app. macOS's privacy grants (Screen Recording, Accessibility)
    /// are stored against the app's designated requirement — `identifier
    /// "com.tide.menubar" and certificate leaf = H"…"` — so a build signed by
    /// any other certificate installs fine but arrives as a stranger to TCC:
    /// System Settings still lists Tide as allowed while every permission
    /// silently stops working. Scripts/build_app.sh pins the one shared
    /// certificate; this is the last line of defence on the receiving end.
    ///
    /// An ad-hoc-signed running copy (no certificate chain at all) has a
    /// cdhash-pinned requirement that no other build could ever satisfy, and
    /// nothing worth protecting — its grants already die on every rebuild —
    /// so the check is skipped for it.
    private static func verifySameSigner(asRunningApp newAppPath: String) throws {
        var runningCode: SecCode?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode else { return }
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, [], &runningStaticCode) == errSecSuccess,
              let runningStaticCode
        else { return }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(runningStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty
        else { return } // ad-hoc: nothing to protect

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(runningStaticCode, [], &requirement) == errSecSuccess,
              let requirement
        else { return }

        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: newAppPath) as CFURL, [], &newCode) == errSecSuccess,
              let newCode,
              SecStaticCodeCheckValidity(newCode, [], requirement) == errSecSuccess
        else {
            throw InstallError.signedByDifferentCertificate
        }
    }

    /// Spawns a detached shell script that waits for this process to quit,
    /// replaces the installed app, and reopens it — then quits this process.
    private static func relaunch(withNewAppAt newAppPath: String) {
        let script = """
        sleep 1
        rm -rf "\(installedAppPath)"
        cp -R "\(newAppPath)" "\(installedAppPath)"
        open "\(installedAppPath)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}
