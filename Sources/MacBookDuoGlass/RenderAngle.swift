import Foundation

// Interpolate the displayed angle, not the sensor's reported precision.
// A repeated target does not restart the transition; a stationary lid settles
// exactly after 40 ms instead of continuing to drift.
struct RenderAngle {
    private var start: Double = 0
    private var target: Double?
    private var startedAt: Double = 0
    let duration: Double = 0.040

    mutating func reset() { target = nil }

    mutating func update(_ angle: Double, at time: Double) {
        guard angle.isFinite, angle != target else { return }
        start = value(at: time) ?? angle
        target = angle
        startedAt = time
    }

    func value(at time: Double) -> Double? {
        guard let target else { return nil }
        let fraction = min(max((time - startedAt) / duration, 0), 1)
        let blend = fraction * fraction * (3 - 2 * fraction)
        return start + (target - start) * blend
    }
}
