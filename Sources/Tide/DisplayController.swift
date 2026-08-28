import AppKit

/// The single place the rest of the app talks to about display hardware.
///
/// Three very different transports sit behind one 0…1 interface:
///
/// | display              | brightness                  | volume    |
/// |----------------------|-----------------------------|-----------|
/// | built-in panel       | DisplayServices (private)   | —         |
/// | external, speaks DDC | DDC/CI VCP 0x10             | VCP 0x62  |
/// | external, no DDC     | software gamma dim          | —         |
///
/// Callers just ask for "brightness on this display"; picking the
/// transport, scaling to the monitor's own value range, and keeping the
/// slow ones off the main thread all happen in here.
final class DisplayController {

    /// One display the menu can offer controls for. `volume` is nil when
    /// the monitor didn't answer a VCP 0x62 probe — most don't have
    /// speakers, and a dead slider is worse than no slider.
    struct ManagedDisplay {
        let info: DisplayInfo
        let supportsVolume: Bool
        var brightness: Float
        var volume: Float
    }

    private enum Transport {
        case builtIn
        case ddc(DDCService, maxBrightness: UInt16, maxVolume: UInt16?)
        case gamma
    }

    private enum Control {
        case brightness
        case volume
    }

    /// Current displays, newest discovery wins. Main thread only.
    private(set) var displays: [ManagedDisplay] = []

    /// Fired on the main thread after the display list changes, so the
    /// menu can be rebuilt.
    var onDisplaysChanged: (() -> Void)?

    /// DDC is slow (tens of milliseconds per exchange, with retries), so
    /// every write goes through this queue rather than stalling the menu
    /// while the user drags a slider.
    private let ddcQueue = DispatchQueue(label: "com.tide.display.ddc", qos: .userInitiated)

    /// Guards `transports` and `pendingWrites`, both touched from the main
    /// thread and from ddcQueue.
    private let lock = NSLock()
    private var transports: [CGDirectDisplayID: Transport] = [:]
    private var pendingWrites: [PendingKey: Float] = [:]
    private var isFlushScheduled = false

    private struct PendingKey: Hashable {
        let displayID: CGDirectDisplayID
        let control: Control
    }

    private var isRefreshing = false
    private var needsAnotherRefresh = false
    private var screenChangeObserver: NSObjectProtocol?
    private var rediscoverWorkItem: DispatchWorkItem?

    // MARK: - Lifecycle

    func start() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        }
        refresh()
    }

    /// Called on quit. A gamma ramp outlives the process that installed
    /// it, so without this a dimmed display would stay dim with no app
    /// left to undo it.
    func shutDown() {
        GammaDimmer.releaseAll()
    }

    private func screenParametersChanged() {
        // Plugging a monitor in fires this several times in a row while
        // the display arrangement settles, and DDC discovery on a monitor
        // that's still negotiating just times out. Waiting for the dust to
        // settle is both faster and more reliable than racing it.
        rediscoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.refresh() }
        rediscoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    // MARK: - Discovery

    func refresh() {
        guard DisplaySettingsStore.isEnabled else {
            displays = []
            lock.lock(); transports.removeAll(); lock.unlock()
            GammaDimmer.releaseAll()
            onDisplaysChanged?()
            return
        }

        // Discovery talks to the hardware, so a second run started while
        // the first is still going would interleave two DDC conversations
        // on the same wire. Coalesce instead.
        guard !isRefreshing else {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true

        // NSScreen is main-thread-only, so the display list is gathered
        // here and only the hardware probing moves to the background.
        let infos = DisplayInfo.onlineDisplays()

        ddcQueue.async { [weak self] in
            guard let self else { return }
            let probed = Self.probe(infos)
            DispatchQueue.main.async {
                self.applyProbeResults(probed)
                self.isRefreshing = false
                if self.needsAnotherRefresh {
                    self.needsAnotherRefresh = false
                    self.refresh()
                }
            }
        }
    }

    private struct ProbeResult {
        let info: DisplayInfo
        let transport: Transport
        let brightness: Float
        let volume: Float?
    }

    /// Runs on ddcQueue: picks a transport per display and reads its
    /// current values once. Values are read here and only here — a DDC
    /// read costs ~100ms, so doing it every time the menu opens would make
    /// the menu visibly stutter. From here on the app trusts what it
    /// itself wrote.
    private static func probe(_ infos: [DisplayInfo]) -> [ProbeResult] {
        let services = DisplaySettingsStore.forceGamma ? [:] : DDCService.discover(for: infos)

        return infos.compactMap { info in
            if info.isBuiltIn {
                guard BuiltInBrightness.isSupported(displayID: info.id) else { return nil }
                return ProbeResult(
                    info: info,
                    transport: .builtIn,
                    brightness: BuiltInBrightness.get(displayID: info.id) ?? 0.5,
                    volume: nil
                )
            }

            if let service = services[info.id], let brightness = service.read(.brightness) {
                let volume = service.read(.volume)
                NSLog("Tide: DDC ready on \"\(info.name)\" — brightness \(brightness.current)/\(brightness.max)"
                    + (volume.map { ", volume \($0.current)/\($0.max)" } ?? ", no volume"))
                return ProbeResult(
                    info: info,
                    transport: .ddc(service, maxBrightness: brightness.max, maxVolume: volume?.max),
                    brightness: Float(brightness.current) / Float(brightness.max),
                    volume: volume.map { Float($0.current) / Float($0.max) }
                )
            }

            NSLog("Tide: no DDC on \"\(info.name)\"; falling back to software dimming")
            return ProbeResult(info: info, transport: .gamma, brightness: 1, volume: nil)
        }
    }

    /// Runs on the main thread: publishes the probe results and re-applies
    /// whatever the user had last chosen for each display.
    private func applyProbeResults(_ results: [ProbeResult]) {
        let liveIDs = Set(results.map { $0.info.id })
        for id in transportKeys() where !liveIDs.contains(id) {
            GammaDimmer.release(displayID: id)
        }

        lock.lock()
        transports = Dictionary(uniqueKeysWithValues: results.map { ($0.info.id, $0.transport) })
        pendingWrites = pendingWrites.filter { liveIDs.contains($0.key.displayID) }
        lock.unlock()

        displays = results.map { result in
            var brightness = result.brightness

            // Only the software-dimmed case gets a saved value restored.
            // macOS remembers the built-in panel's brightness and a DDC
            // monitor remembers its own in firmware, so re-applying a
            // stored value to either would just overwrite whatever the
            // user has since done with the brightness keys or the
            // monitor's own buttons. A gamma ramp, by contrast, is gone
            // the moment the app quits or the cable is pulled.
            if case .gamma = result.transport,
               let saved = DisplaySettingsStore.gammaBrightness(for: result.info.persistenceKey),
               saved < 1 {
                brightness = saved
                write(.brightness, value: saved, displayID: result.info.id, transport: result.transport)
            }

            return ManagedDisplay(
                info: result.info,
                supportsVolume: result.volume != nil,
                brightness: brightness,
                volume: result.volume ?? 0
            )
        }

        onDisplaysChanged?()
    }

    /// Re-reads the values that are cheap to read, and returns the ones
    /// that have drifted since the last look.
    ///
    /// Called when the menu opens, so the built-in display's slider agrees
    /// with what the keyboard's brightness keys have been doing behind the
    /// app's back. DDC displays are deliberately skipped: a read there
    /// costs ~100ms per monitor and would show up as the menu hanging
    /// before it draws.
    func refreshFastValues() -> [CGDirectDisplayID: Float] {
        var changed: [CGDirectDisplayID: Float] = [:]
        for (index, display) in displays.enumerated() {
            guard case .builtIn? = transport(for: display.info.id),
                  let current = BuiltInBrightness.get(displayID: display.info.id),
                  abs(current - display.brightness) > 0.001
            else { continue }
            displays[index].brightness = current
            changed[display.info.id] = current
        }
        return changed
    }

    private func transportKeys() -> [CGDirectDisplayID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(transports.keys)
    }

    // MARK: - Setting values

    func setBrightness(_ value: Float, forDisplayID id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.info.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        displays[index].brightness = clamped

        let transport = transport(for: id)
        // Only worth saving for the transport that can't remember for
        // itself — see DisplaySettingsStore.
        if case .gamma = transport {
            DisplaySettingsStore.setGammaBrightness(clamped, for: displays[index].info.persistenceKey)
        }
        write(.brightness, value: clamped, displayID: id, transport: transport)
    }

    func setVolume(_ value: Float, forDisplayID id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.info.id == id }), displays[index].supportsVolume
        else { return }
        let clamped = min(max(value, 0), 1)
        displays[index].volume = clamped
        write(.volume, value: clamped, displayID: id, transport: transport(for: id))
    }

    private func transport(for id: CGDirectDisplayID) -> Transport? {
        lock.lock()
        defer { lock.unlock() }
        return transports[id]
    }

    /// Built-in and gamma writes land immediately — both are a single fast
    /// function call. Only DDC, which has to hold a conversation with the
    /// monitor, gets queued and coalesced.
    private func write(_ control: Control, value: Float, displayID: CGDirectDisplayID, transport: Transport?) {
        switch transport {
        case .builtIn:
            guard control == .brightness else { return }
            BuiltInBrightness.set(displayID: displayID, brightness: value)
        case .gamma:
            guard control == .brightness else { return }
            GammaDimmer.apply(displayID: displayID, brightness: value)
        case .ddc:
            enqueueDDCWrite(control, value: value, displayID: displayID)
        case nil:
            break
        }
    }

    /// Dragging a slider fires dozens of changes a second; DDC can absorb
    /// maybe twenty. So only the *latest* value per control is kept —
    /// intermediate positions are dropped rather than queued, which is
    /// what makes the monitor track the slider instead of lagging seconds
    /// behind it.
    private func enqueueDDCWrite(_ control: Control, value: Float, displayID: CGDirectDisplayID) {
        lock.lock()
        pendingWrites[PendingKey(displayID: displayID, control: control)] = value
        let needsStart = !isFlushScheduled
        isFlushScheduled = true
        lock.unlock()

        guard needsStart else { return }
        ddcQueue.async { [weak self] in self?.flushPendingWrites() }
    }

    private func flushPendingWrites() {
        while true {
            lock.lock()
            guard let entry = pendingWrites.first else {
                isFlushScheduled = false
                lock.unlock()
                return
            }
            pendingWrites.removeValue(forKey: entry.key)
            let transport = transports[entry.key.displayID]
            lock.unlock()

            guard case let .ddc(service, maxBrightness, maxVolume) = transport else { continue }

            switch entry.key.control {
            case .brightness:
                service.write(.brightness, value: scale(entry.value, to: maxBrightness))
            case .volume:
                guard let maxVolume else { continue }
                service.write(.volume, value: scale(entry.value, to: maxVolume))
            }
        }
    }

    /// Monitors report their own range (almost always 0…100, but the spec
    /// allows anything up to 65535), so the 0…1 the UI works in is scaled
    /// to whatever this particular panel expects.
    private func scale(_ value: Float, to maximum: UInt16) -> UInt16 {
        UInt16(min(max((value * Float(maximum)).rounded(), 0), Float(maximum)))
    }
}
