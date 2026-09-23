import AppKit

final class ThresholdMenuView: NSView {
    var onChange: ((Double) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "效果启动角度")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: EffectModel.clearThreshold,
        minValue: EffectModel.minimumThreshold,
        maxValue: EffectModel.maximumThreshold,
        target: nil,
        action: nil)

    init(threshold: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 58))
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor

        slider.minValue = EffectModel.minimumThreshold
        slider.maxValue = EffectModel.maximumThreshold
        slider.numberOfTickMarks = 10
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.controlSize = .small

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)
        setThreshold(threshold)
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

    func setThreshold(_ value: Double) {
        let clamped = EffectModel.clampThreshold(value)
        slider.doubleValue = clamped
        valueLabel.stringValue = String(format: "%.0f°", clamped)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let threshold = EffectModel.clampThreshold(sender.doubleValue.rounded())
        setThreshold(threshold)
        onChange?(threshold)
    }
}
