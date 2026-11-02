import Foundation
import Combine

// Drives a timed session. The Sensate's default track ("Be Sensate") is ~10 minutes
// long. Depending on firmware behavior the track either loops at EOF or stops; this
// engine re-issues play near each 10-minute boundary until the chosen session length
// elapses, then sends stop. If the device loops natively the re-trigger is a harmless
// seamless restart, so this logic is correct in both cases.

final class SessionEngine: ObservableObject {
    struct Config {
        var minutes: Int = 60
        var volumePercent: Int = 100
    }

    @Published var active = false
    @Published var remaining: TimeInterval = 0
    @Published var total: TimeInterval = 1
    @Published var sessionLog: String = ""

    private var config = Config()
    private var endDate: Date?
    private var timer: AnyCancellable?
    private var nextRetrigger: Date?
    static let trackLength: TimeInterval = 600   // 10-minute default track
    static let retriggerLead: TimeInterval = 2   // re-fire just before boundary

    func start(_ cfg: Config, ble: SensateBLE) {
        config = cfg
        endDate = Date().addingTimeInterval(TimeInterval(cfg.minutes) * 60)
        nextRetrigger = Date().addingTimeInterval(Self.trackLength - Self.retriggerLead)
        active = true
        remaining = TimeInterval(cfg.minutes) * 60
        total = max(1, remaining)
        log("session start — \(cfg.minutes) min @ \(cfg.volumePercent)%")
        ble.startPlayback(volumePercent: cfg.volumePercent)
        runTimer(ble)
    }

    private func runTimer(_ ble: SensateBLE) {
        timer?.cancel()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let end = self.endDate else { return }
                self.remaining = max(0, end.timeIntervalSinceNow)
                if let nr = self.nextRetrigger, Date() >= nr {
                    self.nextRetrigger = nr.addingTimeInterval(Self.trackLength)
                    self.log("re-trigger play (\(Int(self.remaining / 60)) min left)")
                    ble.startPlayback(volumePercent: self.config.volumePercent)
                }
                if self.remaining <= 0 {
                    self.stop(ble)
                }
            }
    }

    func stop(_ ble: SensateBLE) {
        timer?.cancel()
        timer = nil
        endDate = nil
        nextRetrigger = nil
        if active {
            log("session stop")
            ble.stopPlayback()
        }
        active = false
    }

    private func log(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        sessionLog = stamp + "  " + s + "\n" + sessionLog
    }
}
