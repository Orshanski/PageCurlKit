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
            curl.configuration = config
            // The spine band follows the lamp and the shadow's strength too.
            applySpineShadow(config)
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
            settingsPanel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
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

    private func applySpineShadow(_ configuration: PageCurlConfiguration) {
        guard let spreadView, pagesPerSpread == 2 else { return }
        guard configuration.spineShadow != nil else {
            spineShadowView?.removeFromSuperview()
            spineShadowView = nil
            return
        }
        let shadow = spineShadowView ?? {
            let created = SpineShadowView(configuration: configuration)
            spreadView.addSubview(created)
            spineShadowView = created
            return created
        }()
        shadow.configuration = configuration
        shadow.frame = SpineShadowView.frame(forSpreadBounds: spreadView.bounds, configuration: configuration)
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
        if capacity == 2, let configuration = curl?.configuration, configuration.spineShadow != nil {
            let shadow = SpineShadowView(configuration: configuration)
            shadow.frame = SpineShadowView.frame(forSpreadBounds: spread.bounds, configuration: configuration)
            spread.addSubview(shadow)
        }
        return spread
    }

    private func makePageView(index: Int) -> UIView {
        let page = UIView()
        page.backgroundColor = paperColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.firstLineHeadIndent = 24
        paragraph.lineSpacing = 3
        paragraph.hyphenationFactor = 1
        let body = NSAttributedString(
            string: Self.pageText(index: index),
            attributes: [
                .font: UIFont(name: "Georgia", size: 19) ?? .systemFont(ofSize: 19),
                .foregroundColor: UIColor(white: 0.1, alpha: 1),
                .paragraphStyle: paragraph,
            ]
        )
        let text = UILabel()
        text.attributedText = body
        text.numberOfLines = 0
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        page.addSubview(text)

        let number = UILabel()
        number.text = "\(index + 1)"
        number.font = .systemFont(ofSize: 15)
        number.textColor = .gray
        number.textAlignment = .center
        number.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(number)

        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: page.topAnchor, constant: 64),
            text.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 56),
            text.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -56),
            text.bottomAnchor.constraint(lessThanOrEqualTo: number.topAnchor, constant: -24),
            number.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            number.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -32),
        ])
        return page
    }

    /// Every page starts at its own paragraph, so neighbouring pages differ while they turn.
    private static func pageText(index: Int) -> String {
        let paragraphs = sampleText.components(separatedBy: "\n")
        let shift = index % paragraphs.count
        return (Array(paragraphs[shift...]) + Array(paragraphs[..<shift])).joined(separator: "\n")
    }

    private static let sampleText = """
    Дорога шла вдоль реки, и с каждой верстой берег становился круче. Ямщик молчал, изредка \
    поглядывая на небо, где с запада медленно надвигалась тяжёлая серая туча. Лошади шли ровно, \
    колокольчик под дугой звенел глухо, будто издалека.
    Станционный дом показался только к вечеру: низкий, с покосившимся крыльцом и тусклым огнём \
    в окне. Смотритель долго разглядывал подорожную, потом вздохнул и сказал, что лошадей нет и \
    до утра не будет. Спорить было бесполезно, и путник, отряхнув снег с шинели, прошёл в комнату.
    В комнате пахло дымом и сушёными яблоками. На стене висели картинки в простых рамках, на столе \
    стоял самовар, давно остывший. Хозяйская дочь, девочка лет двенадцати, принесла свечу и, \
    не сказав ни слова, исчезла за перегородкой.
    Путник сел у окна. За стеклом метель уже разыгралась всерьёз: дорогу замело, ближние деревья \
    едва угадывались в белой мгле. Он подумал, что, пожалуй, и к лучшему задержаться здесь: письмо, \
    которое он вёз, могло подождать ещё день, а усталость за последнюю неделю накопилась такая, \
    что хотелось только тишины.
    Смотритель вернулся с охапкой дров, разжёг печь и, присев на лавку, принялся рассказывать о \
    прежних временах, когда по этой дороге ездили чаще, а станция была шумной и людной. Рассказ \
    тянулся неторопливо, как сама дорога, и путник слушал вполуха, глядя на огонь.
    Под утро метель стихла. Небо очистилось, и над лесом поднялось холодное солнце. Лошадей \
    привели, ямщик, другой, помоложе, весело прикрикнул, и сани снова побежали вдоль реки.
    """
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
