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
            title: "Duration, s", range: 0.15...10,
            read: { Float($0.duration) },
            write: { $0.duration = CFTimeInterval($1) }
        ),
        SliderRow(
            title: "Cone (−1 bottom · 0 cylinder · +1 top)", range: -1...1,
            read: { Float($0.coneShare) },
            write: { $0.coneShare = CGFloat($1) }
        ),
        SliderRow(
            title: "Cylinder radius, × Microsoft", range: 0.3...2,
            read: { Float($0.cylinderRadiusScale) },
            write: { $0.cylinderRadiusScale = CGFloat($1) }
        ),
        SliderRow(
            title: "Eye distance, screen heights", range: 0.5...10,
            read: { Float($0.eyeDistance) },
            write: { $0.eyeDistance = CGFloat($1) }
        ),
        SliderRow(
            title: "Lamp angle, ° (from the right, counter-clockwise)", range: 0...360,
            read: { Float($0.lampAngle) },
            write: { $0.lampAngle = CGFloat($1) }
        ),
        SliderRow(
            title: "Lamp elevation, ° (90 straight above)", range: 5...90,
            read: { Float($0.lampElevation) },
            write: { $0.lampElevation = CGFloat($1) }
        ),
        SliderRow(
            title: "Leaf tone", range: 0...1,
            read: { Float($0.leafTone) },
            write: { $0.leafTone = CGFloat($1) }
        ),
        DemoSettingsPanel.shadowRow("Shadow strength", 0...0.6, \.strength),
        DemoSettingsPanel.shadowRow("Softening per height", 0...1.5, \.softening),
        DemoSettingsPanel.shadowRow("Shadow max width, pt", 0...250, \.maxWidth),
        DemoSettingsPanel.shadowRow("Shadow min width, pt", 0...40, \.minimumWidth),
        SliderRow(
            title: "Back mirror opacity", range: 0...1,
            read: { Float($0.backMirrorOpacity) },
            write: { $0.backMirrorOpacity = CGFloat($1) }
        ),
    ]

    private var sliders: [UISlider] = []
    private var valueLabels: [UILabel] = []
    private let framesControl = UISegmentedControl(items: ["Auto", "60", "120"])

    private static func shadowRow(
        _ title: String, _ range: ClosedRange<Float>, _ field: WritableKeyPath<CurlShadowStyle, CGFloat>
    ) -> SliderRow {
        SliderRow(
            title: title, range: range,
            read: { Float($0.shadow[keyPath: field]) },
            write: { config, value in config.shadow[keyPath: field] = CGFloat(value) }
        )
    }

    private let shadowSwitch = UISwitch()
    private let toneSwitch = UISwitch()
    private let coneReturnSwitch = UISwitch()
    private let spineSwitch = UISwitch()
    private let spineWidthSlider = UISlider()
    private let spineWidthLabel = UILabel()
    private let spineLampSlider = UISlider()
    private let spineLampLabel = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        layer.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let content = scroll.contentLayoutGuide
        // The panel is as tall as its rows until the screen runs out; then the rows scroll.
        let fitsRows = scroll.heightAnchor.constraint(equalTo: content.heightAnchor)
        fitsRows.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            fitsRows,
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

        let shadowTitle = UILabel()
        shadowTitle.text = "Leaf shadow"
        shadowTitle.font = .systemFont(ofSize: 13, weight: .medium)
        shadowTitle.textColor = .white
        shadowSwitch.onTintColor = .systemBlue
        shadowSwitch.addTarget(self, action: #selector(shadowChanged), for: .valueChanged)
        let shadowRow = UIStackView(arrangedSubviews: [shadowTitle, shadowSwitch])
        shadowRow.axis = .horizontal
        stack.addArrangedSubview(shadowRow)

        let toneTitle = UILabel()
        toneTitle.text = "Leaf tone"
        toneTitle.font = .systemFont(ofSize: 13, weight: .medium)
        toneTitle.textColor = .white
        toneSwitch.onTintColor = .systemBlue
        toneSwitch.addTarget(self, action: #selector(toneChanged), for: .valueChanged)
        let toneRow = UIStackView(arrangedSubviews: [toneTitle, toneSwitch])
        toneRow.axis = .horizontal
        stack.addArrangedSubview(toneRow)

        let coneReturnTitle = UILabel()
        coneReturnTitle.text = "Back to a cone after release"
        coneReturnTitle.font = .systemFont(ofSize: 13, weight: .medium)
        coneReturnTitle.textColor = .white
        coneReturnSwitch.onTintColor = .systemBlue
        coneReturnSwitch.addTarget(self, action: #selector(coneReturnChanged), for: .valueChanged)
        let coneReturnRow = UIStackView(arrangedSubviews: [coneReturnTitle, coneReturnSwitch])
        coneReturnRow.axis = .horizontal
        stack.addArrangedSubview(coneReturnRow)

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
            ("Lamp on the spine", spineLampSlider, spineLampLabel, Float(0)...Float(2)),
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
        coneReturnSwitch.isOn = config.coneReturnsAfterRelease
        shadowSwitch.isOn = config.shadow.isEnabled
        toneSwitch.isOn = config.leafTone > 0
        framesControl.selectedSegmentIndex = switch config.preferredFramesPerSecond {
        case 60: 1
        case 120: 2
        default: 0
        }
        // Defaults come from the package rather than being repeated here.
        let spine = config.spineShadow ?? SpineShadowStyle()
        spineSwitch.isOn = config.spineShadow != nil
        spineWidthSlider.value = Float(spine.width)
        spineLampSlider.value = Float(spine.lampInfluence)
        spineLampSlider.isEnabled = config.spineShadow != nil
        spineLampLabel.text = String(format: "%.2f", spineLampSlider.value)
        spineWidthSlider.isEnabled = config.spineShadow != nil
        spineWidthLabel.text = String(format: "%.0f", spineWidthSlider.value)
    }

    @objc private func spineChanged() {
        guard var config = configuration?() else { return }
        if spineSwitch.isOn {
            var style = SpineShadowStyle()
            style.width = CGFloat(spineWidthSlider.value)
            style.lampInfluence = CGFloat(spineLampSlider.value)
            config.spineShadow = style
        } else {
            config.spineShadow = nil
        }
        spineWidthSlider.isEnabled = spineSwitch.isOn
        spineLampSlider.isEnabled = spineSwitch.isOn
        spineWidthLabel.text = String(format: "%.0f", spineWidthSlider.value)
        spineLampLabel.text = String(format: "%.2f", spineLampSlider.value)
        onChange?(config)
    }

    @objc private func sliderChanged(_ slider: UISlider) {
        guard var config = configuration?() else { return }
        let row = rows[slider.tag]
        row.write(&config, slider.value)
        valueLabels[slider.tag].text = String(format: "%.2f", slider.value)
        onChange?(config)
    }

    @objc private func shadowChanged() {
        guard var config = configuration?() else { return }
        config.shadow.isEnabled = shadowSwitch.isOn
        onChange?(config)
        reload()
    }

    @objc private func toneChanged() {
        guard var config = configuration?() else { return }
        config.leafTone = toneSwitch.isOn ? PageCurlConfiguration().leafTone : 0
        onChange?(config)
        reload()
    }

    @objc private func coneReturnChanged() {
        guard var config = configuration?() else { return }
        config.coneReturnsAfterRelease = coneReturnSwitch.isOn
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

