import Foundation

/// Tracks a stationary lid position while the status-bar option is enabled.
/// It deliberately works from delivered angle changes plus a timer: the HID
/// reader coalesces identical reports, so waiting for another identical
/// sample would never prove that the lid stayed still.
struct AdaptiveAngleTracker {
    static let holdDuration: CFTimeInterval = 3.0
    static let movementTolerance: Double = 0.75

    private(set) var candidateAngle: Double?
    private(set) var stableSince: CFTimeInterval?
    private var appliedCandidateAngle: Double?

    mutating func reset() {
        candidateAngle = nil
        stableSince = nil
        appliedCandidateAngle = nil
    }

    mutating func accept(_ sample: AngleSample) {
        guard sample.isValid,
              sample.degrees.isFinite,
              sample.degrees > EffectModel.minimumThreshold else {
            reset()
            return
        }

        if let candidateAngle,
           abs(sample.degrees - candidateAngle) <= Self.movementTolerance {
            // Average small sensor noise into the candidate without
            // restarting the three-second stationary interval.
            self.candidateAngle = candidateAngle * 0.85 + sample.degrees * 0.15
            return
        }

        candidateAngle = sample.degrees
        stableSince = sample.timestamp
        appliedCandidateAngle = nil
    }

    mutating func thresholdIfReady(at time: CFTimeInterval) -> Double? {
        guard let candidateAngle,
              let stableSince,
              time - stableSince >= Self.holdDuration,
              let threshold = EffectModel.adaptiveThreshold(for: candidateAngle) else {
            return nil
        }
        if let appliedCandidateAngle,
           abs(candidateAngle - appliedCandidateAngle) <= Self.movementTolerance {
            return nil
        }
        self.appliedCandidateAngle = candidateAngle
        return threshold
    }
}
