import UIKit
import PageCurlKit

/// A minimal PageCurlKit host, the working version of the README recipe. Landscape shows a spread,
/// portrait a single page. Tap the left third to go back, the right third to go forward.
@MainActor
final class DemoReaderViewController: UIViewController {

    private let pageCount = 8
    private var firstPage = 0
    private var spreadView: UIView?
    private var spineShadowView: SpineShadowView?
    /// Sliders fire on every tick, and re-snapshotting three spreads per tick makes the screen stutter,
    /// so the cache rebuild is delayed.
    private var spineRebuildTask: Task<Void, Never>?
    private var curl: PageCurlController<DemoReaderViewController>?
    private var lastLaidOutSize: CGSize = .zero
    private let pagesContainer = UIView()
    private let settingsPanel = DemoSettingsPanel()
    private let settingsButton = UIButton(type: .system)

    private var transitionQueue: Task<Void, Never>?

    private var pagesPerSpread: Int {
        view.bounds.width > view.bounds.height ? 2 : 1
    }

    let paperColor = UIColor(red: 0.98, green: 0.955, blue: 0.90, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paperColor
        pagesContainer.backgroundColor = paperColor
        pagesContainer.frame = view.bounds
        pagesContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pagesContainer)
        let curl = PageCurlController(host: self, container: pagesContainer)
        self.curl = curl
        curl.warmUp()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        settingsPanel.configuration = { [weak self] in
            self?.curl?.configuration ?? PageCurlConfiguration()
        }
        settingsPanel.onChange = { [weak self] config in
            guard let self, let curl = self.curl else { return }
            let spineChanged = curl.configuration.spineShadow != config.spineShadow
            curl.configuration = config
            guard spineChanged else { return }
            // The visible shadow follows the slider at once; rebuilding the snapshots that include
            // it waits until the slider stops.
            applySpineShadow(config.spineShadow)
            spineRebuildTask?.cancel()
            spineRebuildTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, let curl = self.curl else { return }
                curl.invalidate()
                curl.prefetch()
            }
        }
        settingsPanel.isHidden = true
        view.addSubview(settingsPanel)

        settingsButton.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settingsButton.tintColor = .darkGray
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.addTarget(self, action: #selector(toggleSettings), for: .touchUpInside)
        view.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            settingsButton.widthAnchor.constraint(equalToConstant: 36),
            settingsButton.heightAnchor.constraint(equalToConstant: 36),
            settingsPanel.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 8),
            settingsPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    @objc private func toggleSettings() {
        if settingsPanel.isHidden {
            settingsPanel.reload()
        }
        settingsPanel.isHidden.toggle()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = view.bounds.size
        firstPage -= firstPage % pagesPerSpread
        showSpread()
        curl?.invalidate()
        curl?.prefetch()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let curl else { return }
        let x = recognizer.location(in: view).x
        if x < view.bounds.width / 3 {
            curl.turn(forward: false, isSpread: pagesPerSpread == 2)
        } else if x > view.bounds.width * 2 / 3 {
            curl.turn(forward: true, isSpread: pagesPerSpread == 2)
        }
    }

    private func showSpread() {
        spreadView?.removeFromSuperview()
        let spread = makeSpreadView(firstPage: firstPage, size: view.bounds.size)
        pagesContainer.insertSubview(spread, at: 0)
        spreadView = spread
        spineShadowView = spread.subviews.compactMap { $0 as? SpineShadowView }.first
    }

    private func applySpineShadow(_ style: SpineShadowStyle?) {
        guard let spreadView, pagesPerSpread == 2 else { return }
        guard let style else {
            spineShadowView?.removeFromSuperview()
            spineShadowView = nil
            return
        }
        let shadow = spineShadowView ?? {
            let created = SpineShadowView(style: style)
            spreadView.addSubview(created)
            spineShadowView = created
            return created
        }()
        shadow.style = style
        shadow.frame = SpineShadowView.frame(forSpreadBounds: spreadView.bounds, style: style)
    }

    private func makeSpreadView(firstPage: Int, size: CGSize) -> UIView {
        let spread = UIView(frame: CGRect(origin: .zero, size: size))
        spread.backgroundColor = paperColor
        let capacity = pagesPerSpread
        let pageWidth = size.width / CGFloat(capacity)
        for slot in 0..<capacity {
            let index = firstPage + slot
            guard index < pageCount else { break }
            let page = makePageView(index: index)
            page.frame = CGRect(
                x: CGFloat(slot) * pageWidth, y: 0,
                width: pageWidth, height: size.height
            )
            spread.addSubview(page)
        }
        if capacity == 2, let style = curl?.configuration.spineShadow {
            let shadow = SpineShadowView(style: style)
            shadow.frame = SpineShadowView.frame(forSpreadBounds: spread.bounds, style: style)
            spread.addSubview(shadow)
        }
        return spread
    }

    private func makePageView(index: Int) -> UIView {
        let page = UIView()
        page.backgroundColor = paperColor

        let number = UILabel()
        number.text = "\(index + 1)"
        number.font = .systemFont(ofSize: 180, weight: .thin)
        number.textColor = UIColor(
            hue: CGFloat(index) / CGFloat(pageCount), saturation: 0.55,
            brightness: 0.72, alpha: 1
        )
        number.textAlignment = .center
        number.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(number)

        let caption = UILabel()
        caption.text = "page \(index + 1) of \(pageCount)"
        caption.font = .systemFont(ofSize: 17)
        caption.textColor = .darkGray
        caption.textAlignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(caption)

        NSLayoutConstraint.activate([
            number.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -20),
            caption.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            caption.topAnchor.constraint(equalTo: number.bottomAnchor, constant: 8),
        ])
        return page
    }
}

// MARK: - Taps on the panel and the gear must not turn pages

extension DemoReaderViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard let touched = touch.view else { return true }
        return !touched.isDescendant(of: settingsPanel)
            && !touched.isDescendant(of: settingsButton)
    }
}

// MARK: - PageCurlHost

extension DemoReaderViewController: PageCurlHost {

    var currentPosition: Int { firstPage }

    func canTurn() -> Bool { true }

    func currentSpreadView() -> UIView? {
        spreadView
    }

    func neighbourSpreadView(forward: Bool) -> UIView? {
        guard let neighbour = neighbourFirstPage(forward: forward) else { return nil }
        return makeSpreadView(firstPage: neighbour, size: view.bounds.size)
    }

    func showTarget(forward: Bool) async -> Bool {
        guard let neighbour = neighbourFirstPage(forward: forward) else { return false }
        firstPage = neighbour
        showSpread()
        curl?.prefetch()
        return true
    }

    func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = transitionQueue
        transitionQueue = Task { @MainActor in
            await previous?.value
            await step()
        }
    }

    private func neighbourFirstPage(forward: Bool) -> Int? {
        let target = forward ? firstPage + pagesPerSpread : firstPage - pagesPerSpread
        guard target >= 0, target < pageCount else { return nil }
        return target
    }
}
