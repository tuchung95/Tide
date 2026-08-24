import AppKit

/// Downloads a release .zip, extracts it, and swaps it in for the currently
/// running /Applications/Tide.app — then relaunches. Because this process
/// can't overwrite its own running executable, the actual swap is done by a
/// short detached shell script spawned just before this process quits; the
/// shell keeps running after the parent (this app) exits.
enum UpdateInstaller {

    enum InstallError: Error {
        case downloadFailed
        case extractFailed
        case appNotFoundInArchive
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
