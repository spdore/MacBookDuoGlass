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
    let projectionOnly: Bool
    let intensity: Float
    let perspectiveDegrees: Float
    let blurPixels: Float
    let darken: Float
    let milk: Float
    let grain: Float
    /// Linear lid progress, 0 at the activation angle and 1 fully closed.
    /// Independent of the strength curve, like `perspectiveDegrees`.
    var foldProgress: Float = 0
}

/// How the lid angle is turned into a projected picture.
enum PerspectiveStyle: String, Sendable {
    /// A rigid picture plane that tilts back about the hinge (bottom edge) and is
    /// seen in perspective: the whole screen stays visible, the hinge edge stays
    /// put and the far edge recedes into a trapezoid.
    case foldPlane
    /// The original model: a glass pane swings in front of fixed content and the
    /// picture is resampled through it.
    case classicGlass
}

struct EffectModel {
    static let minimumThreshold: Double = 75.0
    static let maximumThreshold: Double = 120.0
    static let defaultThreshold: Double = 100.0
    static let minimumIntensityCurve: Double = 0.0
    static let maximumIntensityCurve: Double = 4.0
    static let defaultIntensityCurve: Double = 1.7
    static let adaptiveThresholdOffset: Double = 3.0
    // Higher values keep the effect softer just below the threshold and make
    // it build faster as the lid approaches the closed position.
    private static let intensityCurveKey = "effectIntensityCurve"
    private static let thresholdKey = "effectStartAngleDegrees"
    private static var cachedThreshold: Double = {
        let stored = UserDefaults.standard.object(forKey: thresholdKey) as? NSNumber
        return clampThreshold(stored?.doubleValue ?? defaultThreshold)
    }()
    private static var cachedIntensityCurve: Double = {
        let stored = UserDefaults.standard.object(forKey: intensityCurveKey) as? NSNumber
        return clampIntensityCurve(stored?.doubleValue ?? defaultIntensityCurve)
    }()

    private static let perspectiveStyleKey = "effectPerspectiveStyle"
    private static var cachedPerspectiveStyle: PerspectiveStyle = {
        let stored = UserDefaults.standard.string(forKey: perspectiveStyleKey)
        return stored.flatMap(PerspectiveStyle.init(rawValue:)) ?? .foldPlane
    }()

    static var perspectiveStyle: PerspectiveStyle {
        get { cachedPerspectiveStyle }
        set {
            cachedPerspectiveStyle = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: perspectiveStyleKey)
        }
    }

    // Fold-plane geometry. The plane tilts at most `maximumFoldTilt` back about
    // the hinge. About 14° of tilt at the eye distance used by the shader gives
    // the silhouette of the DuoLauncher fold study (far edge ~9% narrower, ~12%
    // shallower); the lid keeps closing well past that, so the maximum is larger.
    static let maximumFoldTiltDegrees: Double = 42
    // The plane dims to black over the last part of the fold, like the study's
    // late fade, so a nearly closed lid does not show a bright sliver.
    static let foldFadeStart: Double = 0.78

    /// Ease-in/ease-out of the linear lid progress (the study's
    /// accelerate-decelerate timing, applied to the lid instead of a clock).
    /// A pure function of the angle: the same angle always gives the same picture.
    static func foldAmount(forProgress progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p * p * (3 - 2 * p)
    }

    static func foldTiltDegrees(forProgress progress: Double) -> Double {
        maximumFoldTiltDegrees * foldAmount(forProgress: progress)
    }

    static func foldFade(forProgress progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        let t = min(max((p - foldFadeStart) / (1 - foldFadeStart), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static var clearThreshold: Double {
        get { cachedThreshold }
        set {
            let value = clampThreshold(newValue)
            cachedThreshold = value
            UserDefaults.standard.set(value, forKey: thresholdKey)
        }
    }

    static var intensityCurve: Double {
        get { cachedIntensityCurve }
        set {
            let value = clampIntensityCurve(newValue)
            cachedIntensityCurve = value
            UserDefaults.standard.set(value, forKey: intensityCurveKey)
        }
    }

    static func clampThreshold(_ value: Double) -> Double {
        min(max(value, minimumThreshold), maximumThreshold)
    }

    static func clampIntensityCurve(_ value: Double) -> Double {
        min(max(value, minimumIntensityCurve), maximumIntensityCurve)
    }

    /// Returns the threshold proposed by the adaptive-angle mode. A common
    /// angle at or below 75° is intentionally ignored; the built-in minimum
    /// protects the display from treating a nearly closed lid as its clear
    /// reference position.
    static func adaptiveThreshold(for angle: Double) -> Double? {
        guard angle.isFinite, angle > minimumThreshold else { return nil }
        return clampThreshold(angle - adaptiveThresholdOffset)
    }

    static func state(angle: Double, isValid: Bool = true,
                      projectionOnly: Bool = false) -> EffectState {
        guard isValid, angle.isFinite else {
            return EffectState(
                angle: angle,
                isValid: false,
                isClear: false,
                projectionOnly: projectionOnly,
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
                projectionOnly: projectionOnly,
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
        let curvedIntensity = projectionOnly ? 0 : Float(intensity(forProgress: progress))
        // Projection follows the physical fold linearly and reaches a maximum
        // equal to the selected activation angle. The curve is reserved for
        // the frosted material response, so changing its slider never changes
        // the projected composition.
        let perspectiveDegrees = Float(clearThreshold * progress)
        return EffectState(
            angle: clampedAngle,
            isValid: true,
            isClear: false,
            projectionOnly: projectionOnly,
            intensity: curvedIntensity,
            perspectiveDegrees: perspectiveDegrees,
            // The shader applies intensity once while computing the
            // spatially varying radius. Keeping this as the maximum radius
            // avoids applying the fold curve twice.
            blurPixels: projectionOnly ? 0 : 48,
            darken: 0.14 * curvedIntensity,
            milk: 0.045 * curvedIntensity,
            grain: 0.004 * curvedIntensity,
            foldProgress: Float(progress)
        )
    }

    static func intensity(forProgress progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return 0 }
        guard clamped < 1 else { return 1 }
        guard intensityCurve > 0 else { return clamped }
        let denominator = exp(intensityCurve) - 1
        return (exp(intensityCurve * clamped) - 1) / denominator
    }
}
