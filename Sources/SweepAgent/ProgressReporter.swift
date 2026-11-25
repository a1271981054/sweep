import Foundation

/// Emits throttled single-line JSON progress updates to stderr when
/// `SWEEP_PROGRESS=1` is set in the child process environment.
public enum ProgressReporter {
    private static let enabled = ProcessInfo.processInfo.environment["SWEEP_PROGRESS"] == "1"
    private static let lock = NSLock()
    private static var lastEmit = Date.distantPast
    private static var lastStage = ""

    public static func emit(
        fraction: Double,
        stage: String,
        detail: String = "",
        foundBytes: UInt64? = nil,
        foundItems: Int? = nil,
        force: Bool = false
    ) {
        guard enabled else { return }

        let now = Date()
        let clamped = min(1.0, max(0.0, fraction))
        lock.lock()
        let stageChanged = stage != lastStage
        let elapsed = now.timeIntervalSince(lastEmit)
        if !force && !stageChanged && clamped < 0.999 && elapsed < 0.18 {
            lock.unlock()
            return
        }
        lastEmit = now
        lastStage = stage
        lock.unlock()

        var payload: [String: Any] = [
            "fraction": clamped,
            "stage": detail.isEmpty ? stage : "\(stage) · \(detail)",
        ]
        if let foundBytes { payload["foundBytes"] = foundBytes }
        if let foundItems { payload["foundItems"] = foundItems }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var line = data
        line.append(0x0A)
        FileHandle.standardError.write(line)
    }
}
