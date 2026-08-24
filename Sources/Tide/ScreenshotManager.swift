import AppKit

/// Wraps the system `screencapture` CLI to take selection / window / full
/// screen screenshots. Each capture can go to disk, the clipboard, or both
/// at once, per the caller's `Destinations`. Requires the Screen Recording
/// permission on macOS 10.15+; the system prompts for it automatically on
/// first capture.
final class ScreenshotManager {

    enum Mode {
        case selection
        case window
        case fullScreen

        var arguments: [String] {
            // -x mutes screencapture's own default shutter sound — Tide
            // plays its own (CaptureSound.mp3) once the capture actually
            // finishes, so without -x the user would hear both.
            switch self {
            case .selection:
                return ["-i", "-x"]
            case .window:
                return ["-i", "-W", "-x"]
            case .fullScreen:
                return ["-x"]
            }
        }
    }

    struct Destinations: OptionSet {
        let rawValue: Int
        static let file = Destinations(rawValue: 1 << 0)
        static let clipboard = Destinations(rawValue: 1 << 1)
    }

    enum CaptureOutcome {
        case captured
        case cancelled
    }

    enum CaptureError: Error {
        case processFailed(status: Int32)
    }

    private let screenshotsDirectory: URL

    init() {
        let desktopDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        screenshotsDirectory = desktopDirectory
        try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
    }

    /// Runs `screencapture` for the given mode and destinations. Completion
    /// is called on the main thread with `.cancelled` if the user pressed
    /// Esc during an interactive capture, or an error if the capture itself
    /// failed. Passing an empty `destinations` completes as `.cancelled`
    /// without touching the screen.
    func capture(mode: Mode, destinations: Destinations, completion: @escaping (Result<CaptureOutcome, Error>) -> Void) {
        guard !destinations.isEmpty else {
            completion(.success(.cancelled))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        // screencapture can't take both a file path and -c at once, so when
        // saving to a file is wanted (alone or alongside the clipboard),
        // that's the one real invocation; a same-image clipboard copy is
        // then done by hand from the saved file. Clipboard-only (no file)
        // uses screencapture's own -c instead, since there's no file to
        // mirror from.
        let savesToFile = destinations.contains(.file)
        let fileURL = savesToFile ? screenshotsDirectory.appendingPathComponent(Self.timestampedFilename()) : nil

        if let fileURL {
            process.arguments = mode.arguments + [fileURL.path]
        } else {
            process.arguments = mode.arguments + ["-c"]
        }

        process.terminationHandler = { finishedProcess in
            DispatchQueue.main.async {
                guard let fileURL else {
                    completion(.success(finishedProcess.terminationStatus == 0 ? .captured : .cancelled))
                    return
                }

                let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
                guard finishedProcess.terminationStatus == 0 || fileExists else {
                    completion(.failure(CaptureError.processFailed(status: finishedProcess.terminationStatus)))
                    return
                }
                guard fileExists else {
                    completion(.success(.cancelled))
                    return
                }

                if destinations.contains(.clipboard), let image = NSImage(contentsOf: fileURL) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                }

                completion(.success(.captured))
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
