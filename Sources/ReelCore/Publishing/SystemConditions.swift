import Foundation
import Network
#if canImport(IOKit)
import IOKit.ps
#endif

/// Reads battery, network and disk state for `PublishGate`.
public final class SystemConditions: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private let diskURL: URL

    public init(diskURL: URL = LibraryStore.defaultRoot) {
        self.diskURL = diskURL
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.online = path.status == .satisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "reelmanager.network"))
    }

    deinit { monitor.cancel() }

    public func snapshot() -> SystemSnapshot {
        lock.lock(); let isOnline = online; lock.unlock()
        let battery = Self.battery()
        return SystemSnapshot(batteryPercent: battery.percent, onBattery: battery.onBattery,
                              online: isOnline, freeDiskGB: freeDiskGB())
    }

    private func freeDiskGB() -> Double? {
        let values = try? diskURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_000_000_000 }
    }

    static func battery() -> (percent: Int?, onBattery: Bool) {
        #if canImport(IOKit)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = d[kIOPSPowerSourceStateKey] as? String
            return (max > 0 ? current * 100 / max : nil, state == kIOPSBatteryPowerValue)
        }
        #endif
        return (nil, false)
    }
}
