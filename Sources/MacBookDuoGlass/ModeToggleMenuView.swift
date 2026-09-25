import AppKit

/// A compact menu-row switch matching the native macOS Settings control.
/// NSSwitch supplies the white/gray off state and green right-sliding on state
/// using the current system appearance instead of a custom imitation.
final class ModeToggleMenuView: NSView {
    var onChange: ((Bool) -> Void)?

    private let titleLabel: NSTextField
    private let toggle = NSSwitch()

    init(title: String, isOn: Bool, toolTip: String? = nil) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 42))

        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = toolTip

        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.toolTip = toolTip

        addSubview(titleLabel)
        addSubview(toggle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let switchSize = toggle.fittingSize
        toggle.frame = NSRect(
            x: bounds.width - inset - switchSize.width,
            y: (bounds.height - switchSize.height) / 2,
            width: switchSize.width,
            height: switchSize.height
        )
        titleLabel.frame = NSRect(
            x: inset,
            y: (bounds.height - 20) / 2,
            width: max(0, toggle.frame.minX - inset - 12),
            height: 20
        )
    }

    func setOn(_ isOn: Bool) {
        toggle.state = isOn ? .on : .off
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        onChange?(sender.state == .on)
    }
}
