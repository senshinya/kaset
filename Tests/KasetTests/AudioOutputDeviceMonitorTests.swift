import CoreAudio
import Foundation
import Testing
@testable import Kaset

// MARK: - AudioOutputDeviceMonitorTests

/// Tests for `AudioOutputDeviceMonitor`. A stub watcher stands in for Core
/// Audio so the real default-output route is never read or subscribed to.
@Suite(.serialized, .tags(.service))
@MainActor
struct AudioOutputDeviceMonitorTests {
    /// Stands in for Core Audio, modelling the system as a current route plus
    /// the set of routes still attached. `@unchecked Sendable` with a lock
    /// because the protocol is `Sendable` (the production listener fires
    /// off-main), while tests mutate it from the main actor.
    private final class StubWatcher: DefaultOutputRouteWatching, @unchecked Sendable {
        private let lock = NSLock()
        private var route: AudioOutputRoute?
        private var attached: [AudioOutputRoute]
        private var startCount = 0

        init(route: AudioOutputRoute?) {
            self.route = route
            self.attached = [route].compactMap(\.self)
        }

        var watchCount: Int {
            self.lock.withLock { self.startCount }
        }

        /// Switches to `route` while leaving everything attached — a
        /// deliberate output change.
        func switchTo(_ route: AudioOutputRoute?) {
            self.lock.withLock {
                self.route = route
                if let route, !self.attached.contains(route) {
                    self.attached.append(route)
                }
            }
        }

        /// Detaches `lost` and falls back to `route` — an unplug.
        func disconnect(_ lost: AudioOutputRoute, fallingBackTo route: AudioOutputRoute?) {
            self.lock.withLock {
                self.attached.removeAll { $0 == lost }
                self.route = route
                if let route, !self.attached.contains(route) {
                    self.attached.append(route)
                }
            }
        }

        func setRoute(_ route: AudioOutputRoute?) {
            self.lock.withLock { self.route = route }
        }

        func currentDefaultOutputRoute() -> AudioOutputRoute? {
            self.lock.withLock { self.route }
        }

        func isRouteAvailable(_ route: AudioOutputRoute) -> Bool {
            self.lock.withLock { self.attached.contains(route) }
        }

        func startWatching(onChange _: @escaping @Sendable () -> Void) {
            self.lock.withLock { self.startCount += 1 }
        }
    }

    /// Counts monitor callbacks. A class so the escaping closure can mutate it.
    /// The property is deliberately not named `count`: SwiftFormat rewrites
    /// `count == 0` comparisons into `isEmpty`, which this type does not have.
    private final class LossCounter {
        var lossCount = 0
    }

    private struct TestHarness {
        let monitor: AudioOutputDeviceMonitor
        let watcher: StubWatcher
        let losses: LossCounter
    }

    private static let speakers = AudioOutputRoute(deviceID: 41, deviceUID: "speakers", dataSourceIDs: [])
    private static let airPods = AudioOutputRoute(deviceID: 42, deviceUID: "airpods", dataSourceIDs: [])
    private static let display = AudioOutputRoute(deviceID: 43, deviceUID: "display", dataSourceIDs: [])

    /// Same device as the built-in speakers, switched to its headphone data
    /// source — how built-in audio models a jack on some Macs.
    private static let builtInHeadphones = AudioOutputRoute(
        deviceID: 41,
        deviceUID: "speakers",
        dataSourceIDs: [0x6864_706E] // 'hdpn'
    )

    private static let builtInSpeakers = AudioOutputRoute(
        deviceID: 41,
        deviceUID: "speakers",
        dataSourceIDs: [0x6973_706B] // 'ispk'
    )

    /// Zero settle delay keeps the debounce structure (and its cancellation)
    /// intact while letting tests drain it with `Task.yield()`.
    private static func makeHarness(startingRoute: AudioOutputRoute?) -> TestHarness {
        let watcher = StubWatcher(route: startingRoute)
        let monitor = AudioOutputDeviceMonitor(watcher: watcher, settleDelay: .zero)
        let losses = LossCounter()
        monitor.onOutputRouteLost = { losses.lossCount += 1 }
        monitor.start()
        return TestHarness(monitor: monitor, watcher: watcher, losses: losses)
    }

    private static func drain() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }

    @Test("Subscribes to the audio hardware once")
    func startSubscribesOnce() {
        let harness = Self.makeHarness(startingRoute: Self.speakers)

        harness.monitor.start()

        #expect(harness.watcher.watchCount == 1)
    }

    @Test("Losing the device that was playing reports a loss")
    func disconnectedDeviceReportsLoss() async {
        let harness = Self.makeHarness(startingRoute: Self.airPods)

        harness.watcher.disconnect(Self.airPods, fallingBackTo: Self.speakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 1)
    }

    @Test("Switching to a device that is still attached reports nothing")
    func deliberateSwitchReportsNothing() async {
        let harness = Self.makeHarness(startingRoute: Self.speakers)

        harness.watcher.switchTo(Self.airPods)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 0)
    }

    @Test("Connecting a device and later losing it reports only the loss")
    func connectThenDisconnectReportsOnlyTheLoss() async {
        let harness = Self.makeHarness(startingRoute: Self.speakers)

        // Plugging in headphones: macOS switches to them, playback continues.
        harness.watcher.switchTo(Self.airPods)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()
        #expect(harness.losses.lossCount == 0)

        // Pulling them back out.
        harness.watcher.disconnect(Self.airPods, fallingBackTo: Self.speakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()
        #expect(harness.losses.lossCount == 1)
    }

    @Test("A notification that names the same route reports nothing")
    func sameRouteReportsNothing() async {
        let harness = Self.makeHarness(startingRoute: Self.speakers)

        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 0)
    }

    @Test("Losing a data source on the same device reports a loss")
    func lostDataSourceOnSameDeviceReportsLoss() async {
        // Built-in audio on some Macs, and many USB interfaces, expose the
        // headphone jack and the speakers as data sources of one device: an
        // unplug never changes the device ID.
        let harness = Self.makeHarness(startingRoute: Self.builtInHeadphones)

        harness.watcher.disconnect(Self.builtInHeadphones, fallingBackTo: Self.builtInSpeakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 1)
    }

    @Test("Switching data sources on an unchanged device reports nothing")
    func availableDataSourceSwitchReportsNothing() async {
        let harness = Self.makeHarness(startingRoute: Self.builtInHeadphones)

        harness.watcher.switchTo(Self.builtInSpeakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 0)
    }

    @Test("A burst of notifications collapses into a single loss")
    func burstCoalescesIntoOneLoss() async {
        let harness = Self.makeHarness(startingRoute: Self.airPods)

        harness.watcher.disconnect(Self.airPods, fallingBackTo: Self.speakers)
        harness.monitor.handleAudioHardwareChange()
        harness.monitor.handleAudioHardwareChange()
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 1)
    }

    @Test("Each further disconnect reports again")
    func successiveDisconnectsReportEachTime() async {
        let harness = Self.makeHarness(startingRoute: Self.airPods)

        harness.watcher.disconnect(Self.airPods, fallingBackTo: Self.display)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()
        harness.watcher.disconnect(Self.display, fallingBackTo: Self.speakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 2)
    }

    @Test("Losing the last output device reports a loss")
    func losingEveryOutputDeviceReportsLoss() async {
        let harness = Self.makeHarness(startingRoute: Self.airPods)

        // Nothing left to fall back to: the system has no default output.
        harness.watcher.disconnect(Self.airPods, fallingBackTo: nil)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 1)
    }

    @Test("A device arriving after everything was lost reports nothing")
    func deviceArrivingAfterTotalLossReportsNothing() async {
        let harness = Self.makeHarness(startingRoute: Self.airPods)

        harness.watcher.disconnect(Self.airPods, fallingBackTo: nil)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()
        #expect(harness.losses.lossCount == 1)

        harness.watcher.switchTo(Self.speakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 1)
    }

    @Test("An unreadable route reports nothing")
    func unreadableRouteReportsNothing() async {
        let harness = Self.makeHarness(startingRoute: Self.speakers)

        // The route reads as nil while everything is still attached, so
        // nothing disappeared.
        harness.watcher.setRoute(nil)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 0)
    }

    @Test("A transiently unreadable route keeps the baseline for the next disconnect")
    func unreadableRouteKeepsBaseline() async {
        let harness = Self.makeHarness(startingRoute: Self.airPods)

        // Core Audio hiccups: the route reads as nil though nothing detached.
        harness.watcher.setRoute(nil)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()
        #expect(harness.losses.lossCount == 0)

        // The real disconnect still has a baseline to be compared against.
        harness.watcher.disconnect(Self.airPods, fallingBackTo: Self.speakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()

        #expect(harness.losses.lossCount == 1)
    }

    @Test("Without a readable baseline the first route is adopted, not reported")
    func unknownBaselineAdoptsWithoutReporting() async {
        let harness = Self.makeHarness(startingRoute: nil)

        harness.watcher.switchTo(Self.airPods)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()
        #expect(harness.losses.lossCount == 0)

        harness.watcher.disconnect(Self.airPods, fallingBackTo: Self.speakers)
        harness.monitor.handleAudioHardwareChange()
        await Self.drain()
        #expect(harness.losses.lossCount == 1)
    }
}
