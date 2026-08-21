import CoreAudio
import Foundation

// MARK: - AudioOutputRoute

/// Where system audio is actually going.
///
/// The device ID alone is not the route. Built-in audio on some Macs, and many
/// USB interfaces, model the headphone jack and the speakers/line-out as two
/// *data sources* of a single Core Audio device: unplugging headphones there
/// changes the data source while
/// `kAudioHardwarePropertyDefaultOutputDevice` stays put. Comparing device IDs
/// alone would miss exactly the case this feature exists for.
struct AudioOutputRoute: Equatable {
    let deviceID: AudioDeviceID

    /// The device's stable identifier. Core Audio recycles numeric device IDs,
    /// so "is this device still here?" has to be asked by UID. `nil` when the
    /// device does not publish one.
    let deviceUID: String?

    /// The device's currently selected output data sources. Core Audio types
    /// `kAudioDevicePropertyDataSource` as an array, so this is one too; empty
    /// means the device exposes no data-source control at all.
    let dataSourceIDs: [UInt32]
}

// MARK: - DefaultOutputRouteWatching

/// Seam over Core Audio's property listeners. The production implementation
/// talks to real hardware, so tests inject a stub instead of plugging and
/// unplugging headphones.
protocol DefaultOutputRouteWatching: Sendable {
    /// The system's current default output route, or `nil` when Core Audio
    /// refuses to answer (no output device at all, or a transient failure).
    func currentDefaultOutputRoute() -> AudioOutputRoute?

    /// Whether `route` is still present on the system — its device still
    /// attached, and every data source it was playing through still one of
    /// that device's available sources.
    func isRouteAvailable(_ route: AudioOutputRoute) -> Bool

    /// Starts delivering `onChange` whenever the default output device, its
    /// selected data source, or the set of attached devices changes. The
    /// callback arrives on a Core Audio queue, never the main actor, and is
    /// therefore `@Sendable`.
    func startWatching(onChange: @escaping @Sendable () -> Void)
}

// MARK: - CoreAudioDefaultOutputRouteWatcher

/// Core Audio-backed watcher for the default output route.
///
/// Three subscriptions are needed. `kAudioHardwarePropertyDefaultOutputDevice`
/// on the system object catches switches between devices,
/// `kAudioDevicePropertyDataSource` on whichever device is currently default
/// catches switches between that device's own outputs (and has to be
/// re-pointed every time the first one fires), and
/// `kAudioHardwarePropertyDevices` catches attach and detach — the events that
/// decide whether a switch was a disconnect or a choice.
///
/// Deliberately not `@MainActor`: a listener block formed in a MainActor
/// context inherits that isolation and trips Swift 6's runtime isolation check
/// (`dispatch_assert_queue_fail`) the first time Core Audio fires it off-main.
/// Keeping the whole type non-isolated makes its blocks non-isolated too.
final class CoreAudioDefaultOutputRouteWatcher: DefaultOutputRouteWatching, @unchecked Sendable {
    private static let logger = DiagnosticsLogger.player

    /// Guards the data-source subscription, which is re-pointed from Core
    /// Audio's callback queue.
    private let lock = NSLock()
    private var trackedDeviceID: AudioDeviceID?
    private var trackedDataSourceListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var selectedDataSourceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var availableDataSourcesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSources,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: Reading

    func currentDefaultOutputRoute() -> AudioOutputRoute? {
        guard let deviceID = Self.defaultOutputDeviceID(),
              let dataSourceIDs = Self.selectedOutputDataSourceIDs(of: deviceID)
        else { return nil }
        return AudioOutputRoute(
            deviceID: deviceID,
            deviceUID: Self.deviceUID(of: deviceID),
            dataSourceIDs: dataSourceIDs
        )
    }

    func isRouteAvailable(_ route: AudioOutputRoute) -> Bool {
        // Every unreadable answer below resolves to "still available". Only a
        // read that positively says the route is gone may pause playback: the
        // cost of a missed pause is one the user can fix by pressing pause,
        // while a pause on a device that never went away is one they cannot
        // predict at all.
        guard let attached = Self.attachedDeviceIDs() else { return true }
        guard let deviceID = Self.attachedDeviceID(matching: route, among: attached) else { return false }
        guard !route.dataSourceIDs.isEmpty else { return true }
        // An empty list is degenerate rather than informative: a device that
        // publishes the property always offers at least the source it is
        // playing through.
        guard let available = Self.availableOutputDataSourceIDs(of: deviceID), !available.isEmpty
        else { return true }
        let availableIDs = Set(available)
        return route.dataSourceIDs.allSatisfy(availableIDs.contains)
    }

    /// Finds `route`'s device among those currently attached, by UID where one
    /// is published — numeric IDs are recycled, so a match on ID alone can
    /// name a different device that inherited the number.
    private static func attachedDeviceID(
        matching route: AudioOutputRoute,
        among attached: [AudioDeviceID]
    ) -> AudioDeviceID? {
        guard let uid = route.deviceUID else {
            return attached.contains(route.deviceID) ? route.deviceID : nil
        }
        if let match = attached.first(where: { Self.deviceUID(of: $0) == uid }) {
            return match
        }
        // Nothing answered to that UID. Either the device left, or it is still
        // there and momentarily will not say what it is — and those must not
        // be confused. Only the second one keeps the route: the number it held
        // is still attached, and whatever holds it now refuses to identify
        // itself, so it cannot be ruled out as a different device.
        if attached.contains(route.deviceID), Self.deviceUID(of: route.deviceID) == nil {
            return route.deviceID
        }
        return nil
    }

    // MARK: Watching

    func startWatching(onChange: @escaping @Sendable () -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // The data source belongs to a device, so a device switch has to
            // move that subscription before the change is reported.
            self?.retargetDataSourceListener(onChange: onChange)
            onChange()
        }
        for var address in [Self.defaultOutputDeviceAddress, Self.devicesAddress] {
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                nil,
                listener
            )
            if status != noErr {
                Self.logger.warning("failed to listen for audio hardware changes: \(status)")
            }
        }
        self.retargetDataSourceListener(onChange: onChange)
    }

    /// Moves the data-source subscription onto the current default device.
    private func retargetDataSourceListener(onChange: @escaping @Sendable () -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }

        // Sampled inside the lock. Listener blocks registered with a nil queue
        // can overlap, and two callbacks that read the device before locking
        // could commit in reverse order — leaving the subscription on a device
        // that is no longer default, which silently loses every later
        // data-source change.
        let deviceID = Self.defaultOutputDeviceID()
        guard deviceID != self.trackedDeviceID else { return }

        if let previousDeviceID = self.trackedDeviceID,
           let previousListener = self.trackedDataSourceListener
        {
            var address = Self.selectedDataSourceAddress
            _ = AudioObjectRemovePropertyListenerBlock(previousDeviceID, &address, nil, previousListener)
        }
        self.trackedDeviceID = deviceID
        self.trackedDataSourceListener = nil

        guard let deviceID else { return }
        var address = Self.selectedDataSourceAddress
        // Devices with a single fixed output have no data-source property at
        // all; there is simply nothing to subscribe to on those.
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, listener)
        guard status == noErr else {
            Self.logger.warning("failed to listen for output data-source changes: \(status)")
            return
        }
        self.trackedDataSourceListener = listener
    }

    // MARK: Core Audio properties

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.defaultOutputDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Every device currently attached, or `nil` when Core Audio would not
    /// answer — which is not the same as "no devices are attached".
    private static func attachedDeviceIDs() -> [AudioDeviceID]? {
        var address = Self.devicesAddress
        return Self.readUInt32Array(AudioObjectID(kAudioObjectSystemObject), address: &address)
    }

    private static func deviceUID(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid = value?.takeRetainedValue() else { return nil }
        return uid as String
    }

    /// The device's selected output data sources: `[]` when it has no
    /// data-source control at all, and `nil` when it has one but Core Audio
    /// would not answer.
    ///
    /// The two must stay distinct. Collapsing a failed read into `[]` would
    /// read as "the selection changed to nothing" against a device that had a
    /// selection a moment ago, acting on a route that never moved.
    private static func selectedOutputDataSourceIDs(of deviceID: AudioDeviceID) -> [UInt32]? {
        var address = Self.selectedDataSourceAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return [] }
        return Self.readUInt32Array(deviceID, address: &address)
    }

    /// Every output data source the device currently offers, or `nil` when it
    /// has no data-source control or Core Audio would not answer.
    private static func availableOutputDataSourceIDs(of deviceID: AudioDeviceID) -> [UInt32]? {
        var address = Self.availableDataSourcesAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        return Self.readUInt32Array(deviceID, address: &address)
    }

    /// Reads an array-valued `UInt32` property, sizing the buffer from Core
    /// Audio rather than assuming a single element. Returns `nil` on failure.
    private static func readUInt32Array(
        _ objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> [UInt32]? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
        let capacity = Int(size) / MemoryLayout<UInt32>.size
        guard capacity > 0 else { return [] }
        var values = [UInt32](repeating: 0, count: capacity)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values) == noErr else { return nil }
        // Core Audio reports back how much it actually wrote.
        let written = Int(size) / MemoryLayout<UInt32>.size
        return Array(values.prefix(written))
    }
}

// MARK: - AudioOutputDeviceMonitor

/// Watches the system's default audio output route and reports when the route
/// playback was using *disappears* — headphones unplugged, AirPods
/// disconnected, an interface pulled out.
///
/// Switching to a device that is still attached is not a disappearance and is
/// not reported: choosing a different output in Control Center, or connecting
/// headphones, leaves playback alone. This mirrors the one route change iOS
/// tells apps to stop for, `oldDeviceUnavailable`. macOS surfaces no such
/// reason code, so it has to be inferred by asking whether the previous route
/// is still attached.
///
/// Core Audio fires its listeners for every notification, which includes
/// bursts while a device settles and repeats that name the route already in
/// use, so the monitor debounces before deciding anything.
///
/// Note: picking an AirPlay target inside the playback WebView does not change
/// the system default output device, so in-app AirPlay routing never trips
/// this monitor.
@MainActor
final class AudioOutputDeviceMonitor {
    /// Called after the route playback was using disappeared. Set before
    /// ``start()``.
    var onOutputRouteLost: (@MainActor () -> Void)?

    private let watcher: any DefaultOutputRouteWatching
    private let settleDelay: Duration
    private let logger = DiagnosticsLogger.player

    /// The route seen at the last notification (or at ``start()``). `nil`
    /// means Core Audio never gave us a readable baseline.
    private var lastKnownRoute: AudioOutputRoute?
    private var hasStarted = false
    private var settleTask: Task<Void, Never>?

    init(
        watcher: any DefaultOutputRouteWatching = CoreAudioDefaultOutputRouteWatcher(),
        settleDelay: Duration = .milliseconds(50)
    ) {
        self.watcher = watcher
        self.settleDelay = settleDelay
    }

    /// Records the current route as the baseline and subscribes to changes.
    func start() {
        guard !self.hasStarted else { return }
        self.hasStarted = true
        self.lastKnownRoute = self.watcher.currentDefaultOutputRoute()
        self.watcher.startWatching { [weak self] in
            Task { @MainActor in
                self?.handleAudioHardwareChange()
            }
        }
    }

    /// Core Audio reported a hardware notification. Internal rather than
    /// private so tests can drive it without real hardware.
    func handleAudioHardwareChange() {
        // A disconnect produces several notifications in a row — the device
        // list, the default device, sometimes the data source. Only the
        // settled state answers whether the old route is gone, so let the
        // burst finish before asking.
        self.settleTask?.cancel()
        self.settleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.settleDelay > .zero {
                try? await Task.sleep(for: self.settleDelay)
            }
            guard !Task.isCancelled else { return }
            self.notifyIfRouteLost()
        }
    }

    private func notifyIfRouteLost() {
        let current = self.watcher.currentDefaultOutputRoute()
        guard let previous = self.lastKnownRoute else {
            // No baseline to compare against, so nothing can be claimed to
            // have disappeared. Adopt whatever is there now.
            self.lastKnownRoute = current
            return
        }
        guard current != previous else { return }

        // Ask before adopting: once the baseline moves, the route that may
        // have vanished is no longer known.
        let previousIsStillAttached = self.watcher.isRouteAvailable(previous)

        guard !previousIsStillAttached else {
            // An unreadable current route with the previous one still attached
            // says nothing happened. Keeping the baseline matters: adopting
            // `nil` would leave the next genuine disconnect with nothing to
            // compare against, and it would go unnoticed.
            if current != nil {
                self.lastKnownRoute = current
                self.logger.info("Audio output route changed; previous route still attached")
            }
            return
        }
        // `nil` here means the last output device went away without a
        // replacement. The next device to appear is a fresh baseline, not a
        // second disappearance.
        self.lastKnownRoute = current
        self.logger.info("Audio output route disappeared")
        self.onOutputRouteLost?()
    }
}
