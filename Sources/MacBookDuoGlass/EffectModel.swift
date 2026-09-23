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
    // Higher values keep the effect softer just below the threshold and make
    // it build faster as the lid approaches the closed position.
    static let intensityCurve: Double = 1.7
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

        // The effect starts at the selected threshold with 0% strength and
        // reaches 100% at 0°. An exponential ease-in keeps the first part of
        // the fold subtle, then increases the effect more quickly near 0°.
        let progress = min(max((clearThreshold - clampedAngle) / clearThreshold, 0), 1)
        let curvedIntensity = Float(intensity(forProgress: progress))
        return EffectState(
            angle: clampedAngle,
            isValid: true,
            isClear: false,
            intensity: curvedIntensity,
            perspectiveDegrees: 55 * curvedIntensity,
            // The shader applies intensity once while computing the
            // spatially varying radius. Keeping this as the maximum radius
            // avoids applying the fold curve twice.
            blurPixels: 48,
            darken: 0.14 * curvedIntensity,
            milk: 0.045 * curvedIntensity,
            grain: 0.004 * curvedIntensity
        )
    }

    static func intensity(forProgress progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return 0 }
        guard clamped < 1 else { return 1 }
        let denominator = exp(intensityCurve) - 1
        return (exp(intensityCurve * clamped) - 1) / denominator
    }
}
