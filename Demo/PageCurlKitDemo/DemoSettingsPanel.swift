import UIKit
import PageCurlKit

/// Sliders for tuning the curl. Changes go to the live controller configuration and apply from the
/// next turn.
@MainActor
final class DemoSettingsPanel: UIView {

    var configuration: (() -> PageCurlConfiguration)?
    var onChange: ((PageCurlConfiguration) -> Void)?

    private struct SliderRow {
        let title: String
        let range: ClosedRange<Float>
        let read: (PageCurlConfiguration) -> Float
        let write: (inout PageCurlConfiguration, Float) -> Void
    }

    private let rows: [SliderRow] = [
        SliderRow(
            title: "Duration, s", range: 0.15...1.5,
            read: { Float($0.duration) },
            write: { $0.duration = CFTimeInterval($1) }
        ),
        SliderRow(
            title: "Spread radius", range: 0.05...0.40,
            read: { Float($0.spreadStartRadiusFraction) },
            write: { $0.spreadStartRadiusFraction = CGFloat($1) }
        ),
        SliderRow(
            title: "Single-page radius", range: 0.05...0.40,
            read: { Float($0.singleStartRadiusFraction) },
            write: { $0.singleStartRadiusFraction = CGFloat($1) }
        ),
        SliderRow(
            title: "Cone strength", range: 0...0.20,
            read: { Float($0.coneStrength) },
            write: { $0.coneStrength = CGFloat($1) }
        ),
        SliderRow(
            title: "Shadow", range: 0...1,
            read: { Float($0.shadowStrength) },
            write: { $0.shadowStrength = CGFloat($1) }
        ),
        SliderRow(
            title: "Back mirror opacity", range: 0...1,
            read: { Float($0.backMirrorOpacity) },
            write: { $0.backMirrorOpacity = CGFloat($1) }
        ),
    ]

    private var sliders: [UISlider] = []
    private var valueLabels: [UILabel] = []
    private let framesControl = UISegmentedControl(items: ["Auto", "60", "120"])

    private let spineSwitch = UISwitch()
    private let spineWidthSlider = UISlider()
    private let spineWidthLabel = UILabel()
    private let spineStrengthSlider = UISlider()
    private let spineStrengthLabel = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        layer.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            widthAnchor.constraint(equalToConstant: 340),
        ])

        for (index, row) in rows.enumerated() {
            let title = UILabel()
            title.text = row.title
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.textColor = .white

            let value = UILabel()
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            value.textColor = UIColor(white: 1, alpha: 0.7)
            value.textAlignment = .right
            valueLabels.append(value)

            let header = UIStackView(arrangedSubviews: [title, value])
            header.axis = .horizontal

            let slider = UISlider()
            slider.minimumValue = row.range.lowerBound
            slider.maximumValue = row.range.upperBound
            slider.tag = index
            slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
            sliders.append(slider)

            stack.addArrangedSubview(header)
            stack.addArrangedSubview(slider)
        }

        let framesTitle = UILabel()
        framesTitle.text = "Frames per second"
        framesTitle.font = .systemFont(ofSize: 13, weight: .medium)
        framesTitle.textColor = .white
        stack.addArrangedSubview(framesTitle)
        framesControl.selectedSegmentTintColor = .systemBlue
        framesControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        framesControl.addTarget(self, action: #selector(framesChanged), for: .valueChanged)
        stack.addArrangedSubview(framesControl)

        let spineTitle = UILabel()
        spineTitle.text = "Spine shadow"
        spineTitle.font = .systemFont(ofSize: 13, weight: .medium)
        spineTitle.textColor = .white
        spineSwitch.onTintColor = .systemBlue
        spineSwitch.addTarget(self, action: #selector(spineChanged), for: .valueChanged)
        let spineHeader = UIStackView(arrangedSubviews: [spineTitle, spineSwitch])
        spineHeader.axis = .horizontal
        stack.addArrangedSubview(spineHeader)

        for (title, slider, label, range) in [
            ("Spine width", spineWidthSlider, spineWidthLabel, Float(10)...Float(100)),
            ("Spine strength", spineStrengthSlider, spineStrengthLabel, Float(0)...Float(0.5)),
        ] {
            let rowTitle = UILabel()
            rowTitle.text = title
            rowTitle.font = .systemFont(ofSize: 13, weight: .medium)
            rowTitle.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            label.textColor = UIColor(white: 1, alpha: 0.7)
            label.textAlignment = .right
            let header = UIStackView(arrangedSubviews: [rowTitle, label])
            header.axis = .horizontal
            slider.minimumValue = range.lowerBound
            slider.maximumValue = range.upperBound
            slider.addTarget(self, action: #selector(spineChanged), for: .valueChanged)
            stack.addArrangedSubview(header)
            stack.addArrangedSubview(slider)
        }

        let reset = UIButton(type: .system)
        reset.setTitle("Reset to defaults", for: .normal)
        reset.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        reset.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        stack.addArrangedSubview(reset)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func reload() {
        guard let config = configuration?() else { return }
        for (index, row) in rows.enumerated() {
            sliders[index].value = row.read(config)
            valueLabels[index].text = String(format: "%.2f", row.read(config))
        }
        framesControl.selectedSegmentIndex = switch config.preferredFramesPerSecond {
        case 60: 1
        case 120: 2
        default: 0
        }
        // Defaults come from the package rather than being repeated here.
        let spine = config.spineShadow ?? SpineShadowStyle()
        spineSwitch.isOn = config.spineShadow != nil
        spineWidthSlider.value = Float(spine.width)
        spineStrengthSlider.value = Float(spine.strength)
        spineWidthSlider.isEnabled = config.spineShadow != nil
        spineStrengthSlider.isEnabled = config.spineShadow != nil
        spineWidthLabel.text = String(format: "%.0f", spineWidthSlider.value)
        spineStrengthLabel.text = String(format: "%.2f", spineStrengthSlider.value)
    }

    @objc private func spineChanged() {
        guard var config = configuration?() else { return }
        if spineSwitch.isOn {
            var style = SpineShadowStyle()
            style.width = CGFloat(spineWidthSlider.value)
            style.strength = CGFloat(spineStrengthSlider.value)
            config.spineShadow = style
        } else {
            config.spineShadow = nil
        }
        spineWidthSlider.isEnabled = spineSwitch.isOn
        spineStrengthSlider.isEnabled = spineSwitch.isOn
        spineWidthLabel.text = String(format: "%.0f", spineWidthSlider.value)
        spineStrengthLabel.text = String(format: "%.2f", spineStrengthSlider.value)
        onChange?(config)
    }

    @objc private func sliderChanged(_ slider: UISlider) {
        guard var config = configuration?() else { return }
        let row = rows[slider.tag]
        row.write(&config, slider.value)
        valueLabels[slider.tag].text = String(format: "%.2f", slider.value)
        onChange?(config)
    }

    @objc private func framesChanged() {
        guard var config = configuration?() else { return }
        config.preferredFramesPerSecond = [0, 60, 120][framesControl.selectedSegmentIndex]
        onChange?(config)
    }

    @objc private func resetTapped() {
        onChange?(PageCurlConfiguration())
        reload()
    }
}
