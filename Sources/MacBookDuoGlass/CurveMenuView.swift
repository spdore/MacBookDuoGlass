import AppKit

final class CurveMenuView: NSView {
    var onChange: ((Double) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "指数曲线参数")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: EffectModel.intensityCurve,
        minValue: EffectModel.minimumIntensityCurve,
        maxValue: EffectModel.maximumIntensityCurve,
        target: nil,
        action: nil)

    init(curve: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 58))
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.toolTip = "数值越大，阈值附近越弱，接近合盖时增长越快"

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor

        slider.minValue = EffectModel.minimumIntensityCurve
        slider.maxValue = EffectModel.maximumIntensityCurve
        slider.numberOfTickMarks = 9
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.controlSize = .small

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)
        setCurve(curve)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        titleLabel.frame = NSRect(x: inset, y: bounds.height - 23,
                                  width: bounds.width - inset * 2 - 54, height: 18)
        valueLabel.frame = NSRect(x: bounds.width - inset - 54, y: bounds.height - 23,
                                  width: 54, height: 18)
        slider.frame = NSRect(x: inset, y: 7, width: bounds.width - inset * 2, height: 22)
    }

    func setCurve(_ value: Double) {
        let clamped = EffectModel.clampIntensityCurve(value)
        slider.doubleValue = clamped
        valueLabel.stringValue = String(format: "%.1f", clamped)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let curve = EffectModel.clampIntensityCurve((sender.doubleValue * 10).rounded() / 10)
        setCurve(curve)
        onChange?(curve)
    }
}
