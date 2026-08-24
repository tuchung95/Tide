import AppKit

/// Wraps the system `screencapture` CLI to take selection / window / full
/// screen screenshots. Each capture is saved to disk and copied to the
/// clipboard. Requires the Screen Recording permission on macOS 10.15+;
/// the system prompts for it automatically on first capture.
final class ScreenshotManager {

    enum Mode {
        case selection
        case window
        case fullScreen

        var arguments: [String] {
            switch self {
            case .selection:
                return ["-i"]
            case .window:
                return ["-i", "-W"]
            case .fullScreen:
                return []
            }
        }
    }

    enum CaptureError: Error {
        case processFailed(status: Int32)
        case fileNotCreated
        case imageLoadFailed
    }

    private let screenshotsDirectory: URL

    init() {
        let desktopDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        screenshotsDirectory = desktopDirectory
        try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
    }

    /// Runs `screencapture` for the given mode. Completion is called on the
    /// main thread with the saved file URL, or nil if the user cancelled an
    /// interactive capture (Esc), or an error if the capture itself failed.
    func capture(mode: Mode, completion: @escaping (Result<URL?, Error>) -> Void) {
        let filename = Self.timestampedFilename()
        let destination = screenshotsDirectory.appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = mode.arguments + [destination.path]

        process.terminationHandler = { finishedProcess in
            DispatchQueue.main.async {
                let fileExists = FileManager.default.fileExists(atPath: destination.path)

                // Interactive captures return a non-zero status when the
                // user cancels (Esc) and no file is written; treat that as
                // a clean cancellation rather than an error.
                guard finishedProcess.terminationStatus == 0 || fileExists else {
                    if !fileExists {
                        completion(.success(nil))
                        return
                    }
                    completion(.failure(CaptureError.processFailed(status: finishedProcess.terminationStatus)))
                    return
                }

                guard fileExists else {
                    completion(.success(nil))
                    return
                }

                guard let image = NSImage(contentsOf: destination) else {
                    completion(.failure(CaptureError.imageLoadFailed))
                    return
                }

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])

                completion(.success(destination))
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }

    private static func timestampedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Tide Screenshot \(formatter.string(from: Date())).png"
    }
}
