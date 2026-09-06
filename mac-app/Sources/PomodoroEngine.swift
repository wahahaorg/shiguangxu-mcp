import Foundation

enum Phase: Equatable {
    case idle
    case focus
    case rest
}

/// 番茄钟状态机。所有回调都在主线程触发。
final class PomodoroEngine {
    private(set) var phase: Phase = .idle
    private(set) var phaseStart: Date?
    private var endDate: Date?
    private var pausedRemaining: TimeInterval?
    private var timer: Timer?

    var onTick: ((Phase, TimeInterval) -> Void)?
    var onFocusFinished: ((_ start: Date, _ end: Date, _ seconds: Int) -> Void)?
    var onRestFinished: (() -> Void)?

    var isPaused: Bool { pausedRemaining != nil }
    var isActive: Bool { phase != .idle }

    func remaining() -> TimeInterval {
        if let remaining = pausedRemaining { return remaining }
        guard let end = endDate else { return 0 }
        return max(0, end.timeIntervalSinceNow)
    }

    func startFocus(minutes: Int) {
        start(phase: .focus, minutes: minutes)
    }

    func startRest(minutes: Int) {
        start(phase: .rest, minutes: minutes)
    }

    private func start(phase newPhase: Phase, minutes: Int) {
        phase = newPhase
        phaseStart = Date()
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(Double(max(1, minutes)) * 60)
        startTimer()
    }

    func pause() {
        guard isActive, pausedRemaining == nil else { return }
        pausedRemaining = remaining()
        timer?.invalidate()
        timer = nil
        onTick?(phase, pausedRemaining ?? 0)
    }

    func resume() {
        guard let remaining = pausedRemaining else { return }
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(remaining)
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        phase = .idle
        endDate = nil
        pausedRemaining = nil
        phaseStart = nil
        onTick?(.idle, 0)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func tick() {
        guard phase != .idle else { return }
        let remaining = remaining()
        onTick?(phase, remaining)
        guard remaining <= 0 else { return }
        let start = phaseStart ?? Date().addingTimeInterval(-1)
        let finishedPhase = phase
        let seconds = max(1, Int(Date().timeIntervalSince(start)))
        stop()
        if finishedPhase == .focus {
            onFocusFinished?(start, Date(), seconds)
        } else if finishedPhase == .rest {
            onRestFinished?()
        }
    }
}
