import Foundation

struct AngleSample: Sendable {
    let degrees: Double
    let rawValue: UInt16
    let timestamp: CFTimeInterval
    let isValid: Bool
}

struct EffectState: Sendable {
    let angle: Double
    let isValid: Bool
    let isClear: Bool
    let intensity: Float
    let perspectiveDegrees: Float
    let blurPixels: Float
    let darken: Float
    let milk: Float
    let grain: Float
}

struct EffectModel {
    static let minimumThreshold: Double = 75.0
    static let maximumThreshold: Double = 120.0
    static let defaultThreshold: Double = 100.0
    private static let thresholdKey = "effectStartAngleDegrees"
    private static var cachedThreshold: Double = {
        let stored = UserDefaults.standard.object(forKey: thresholdKey) as? NSNumber
        return clampThreshold(stored?.doubleValue ?? defaultThreshold)
    }()

    static var clearThreshold: Double {
        get { cachedThreshold }
        set {
            let value = clampThreshold(newValue)
            cachedThreshold = value
            UserDefaults.standard.set(value, forKey: thresholdKey)
        }
    }

    static func clampThreshold(_ value: Double) -> Double {
        min(max(value, minimumThreshold), maximumThreshold)
    }

    static func state(angle: Double, isValid: Bool = true) -> EffectState {
        guard isValid, angle.isFinite else {
            return EffectState(
                angle: angle,
                isValid: false,
                isClear: false,
                intensity: 0,
                perspectiveDegrees: 0,
                blurPixels: 0,
                darken: 0,
                milk: 0,
                grain: 0
            )
        }

        let clampedAngle = min(max(angle, 0), 180)
        if clampedAngle >= clearThreshold {
            return EffectState(
                angle: clampedAngle,
                isValid: true,
                isClear: true,
                intensity: 0,
                perspectiveDegrees: 0,
                blurPixels: 0,
                darken: 0,
                milk: 0,
                grain: 0
            )
        }

        // The effect starts at exactly 100° with 0% strength and reaches
        // 100% at 0°. No time-based easing is applied to this mapping.
        let linearIntensity = Float(min(max((clearThreshold - clampedAngle) / clearThreshold, 0), 1))
        return EffectState(
            angle: clampedAngle,
            isValid: true,
            isClear: false,
            intensity: linearIntensity,
            perspectiveDegrees: 55 * linearIntensity,
            // The shader applies intensity once while computing the
            // spatially varying radius. Keeping this as the maximum radius
            // avoids applying the fold curve twice.
            blurPixels: 48,
            darken: 0.14 * linearIntensity,
            milk: 0.045 * linearIntensity,
            grain: 0.004 * linearIntensity
        )
    }
}
