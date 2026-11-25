# PageCurlKit

Metal page-curl turning for a pager of any content: text, PDF, static images.
The library knows nothing about books, sections, or pages — the host provides
spread views and shows them, the library snapshots them and delivers the curl.

Two API layers:

- **Conductor** — `PageCurlController` + the `PageCurlHost` protocol: snapshot
  cache, quiet window, interruption, queueing — the whole mechanics of turning
  with a curl. The controller keeps one curl view for all turns: each snapshot
  becomes a texture once, when it is taken, and is kept only there, so a
  prefetched turn copies no pixels; on Apple GPUs the multisample and depth
  buffers take no memory at all.
- **Bare effect** — `PageCurlOverlayView`: two snapshots in, a self-driving
  animation to completion. For those who only need the render.

## Installation

iOS 17+, Swift 6. Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/Orshanski/PageCurlKit.git", from: "2.0.0")
```

## Every call turns the page

`turn()` is the single entry point for turning. It is synchronous, so you call
it straight from the gesture handler. **Every call turns the page, either with
the curl or instantly.** When the curl is not possible (busy host, rapid
tapping, no Metal, no snapshots), the page is shown instantly; the call is
never dropped. The only call that does nothing is at the edge of the book,
when `showTarget` returns false.

## The host protocol — seven primitives

```swift
extension MyPagerViewController: PageCurlHost {
    // Identifies the spread on screen and keys the snapshot cache. Any
    // Equatable value works; the library only compares it.
    var currentPosition: Int { firstPage }

    // Return false while busy; for a pager with a queue, while it is not empty.
    func canTurn() -> Bool { pendingNavigations == 0 }

    // Paper color: fills transparent areas of the snapshots and colors the
    // back of a single page.
    var paperColor: UIColor { .white }

    // The spread on screen, sized to the container; nil — nothing shown yet.
    func currentSpreadView() -> UIView? { ... }

    // The neighbouring spread, sized to the container and off screen; nil —
    // no neighbour (edge) or not ready yet. In the second case the host kicks
    // off preparation itself and calls prefetch() once ready.
    func neighbourSpreadView(forward: Bool) -> UIView? { ... }

    // Instant show of the target spread; false — nothing was shown (edge).
    func showTarget(forward: Bool) async -> Bool { ... }

    // The host's transition queue; a host without a queue runs the step
    // right away.
    func enqueue(_ step: @escaping @MainActor () async -> Void) { ... }
}
```

## Wiring it up

```swift
// The container is the view the overlay lives on.
let curl = PageCurlController(host: self, container: view)
curl.warmUp() // on open: shaders compile ahead of time, not on the first tap

// The gesture handler, in its entirety:
curl.turn(forward: true, isSpread: pagesPerSpread == 2)
```

## A complete minimal host

A working single-page pager over an array of page views — a condensed
version of the demo app (`Demo/`), which is the living, compilable form of
this snippet:

```swift
@MainActor
final class MiniPagerViewController: UIViewController, PageCurlHost {
    private let pages: [UIView] = makeTenPageViews() // your content
    private var current = 0
    private var shownPage: UIView?
    private var curl: PageCurlController<MiniPagerViewController>?
    private var queue: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paperColor
        curl = PageCurlController(host: self, container: view)
        curl?.warmUp()
        show(page: 0)
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        view.addGestureRecognizer(tap)
    }

    @objc private func onTap(_ recognizer: UITapGestureRecognizer) {
        let forward = recognizer.location(in: view).x > view.bounds.midX
        curl?.turn(forward: forward, isSpread: false)
    }

    private func show(page index: Int) {
        shownPage?.removeFromSuperview()
        let page = pages[index]
        page.frame = view.bounds
        view.insertSubview(page, at: 0)
        shownPage = page
        current = index
        curl?.prefetch() // after every show — the next tap pays no assembly
    }

    // MARK: PageCurlHost

    var currentPosition: Int { current }

    func canTurn() -> Bool { true } // shows are instant, never busy

    var paperColor: UIColor { .white }

    func currentSpreadView() -> UIView? { shownPage }

    func neighbourSpreadView(forward: Bool) -> UIView? {
        let target = forward ? current + 1 : current - 1
        guard pages.indices.contains(target) else { return nil } // the edge
        pages[target].frame = view.bounds
        return pages[target]
    }

    func showTarget(forward: Bool) async -> Bool {
        let target = forward ? current + 1 : current - 1
        guard pages.indices.contains(target) else { return false } // the edge
        show(page: target)
        return true
    }

    func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await step()
        }
    }
}
```

## Host duties not expressed by the types

- **`prefetch()`** — after every show and after a neighbour becomes ready.
  Otherwise every curl pays for on-the-spot snapshot assembly (~0.1 s on
  an iPad). Snapshots are taken one per run loop pass, so the screen updates
  and taps get through between them; a tap stops the rest. During rapid
  tapping (a tap within `duration` of the previous show) each tap shows the
  page instantly and `prefetch()` takes nothing; the snapshots are taken once
  the taps stop for `duration`. The library drops the snapshots in the
  background and on a memory warning. On return to the foreground it
  rebuilds them by itself; after a memory warning they come back with the
  next `prefetch()` or turn.
- **`warmUp()`** — when the pager opens.
- **`interrupt()`** — on host events incompatible with letting the animation
  finish: shows that bypass the library (table of contents, position
  restore), opening a menu. The library interrupts by itself when the app goes
  to the background or the container is resized.
- **`invalidate()`** — when the cache went stale without a position-token
  change: re-layout or a theme change, for example.
- **Spread views are sized to the container.** The library calls
  `layoutIfNeeded()` on them and renders them with `layer.render(in:)` over
  `paperColor`. If a view controller lays the view out, keep that controller
  alive until the next call. Content that `layer.render(in:)` cannot capture
  (video, Metal) will be missing from the curl.
- **`enqueue` serializes steps**: the next one starts after the previous one
  ends. A host without a queue runs the step right away.
- **Neighbours are symmetric.** Turning back from a neighbour leads to the
  spread you came from. After a turn the library keeps the target snapshot as
  current and the old current as the neighbour behind, and snapshots only the
  new neighbour ahead.
- **Expensive spreads are built once.** If building a spread is costly (text
  layout, PDF rendering), keep the view returned from `neighbourSpreadView`
  and show that same view in `showTarget` instead of building it again.

## Configuration

`PageCurlConfiguration`, mutable on a live controller; applies starting with
the next curl:

- **Timing** — `duration`, which is also the quiet window;
  `preferredFramesPerSecond` (0 — device maximum).
- **Shape** — `coneShare` (−1 tight at the bottom corner, 0 a cylinder, +1
  tight at the top corner), `cylinderRadiusScale`, `coneReturnsAfterRelease`,
  `eyeDistance` (in screen heights: nearer makes the lifted leaf grow more).
- **Lamp** — `lampAngle` and `lampElevation`: one lamp for the leaf's tone,
  its shadow and the spine.
- **Tone** — `leafTone`: how much the leaf darkens where it turns away from
  the lamp; 0 — off.
- **Shadow** — `shadow` (`CurlShadowStyle`: on or off, strength, softening per
  point of height, widest and narrowest soft edge). The strength also sets the
  spine band's depth and stays when the shadow is off.
- **Spine** — `spineShadow` (`SpineShadowStyle`, see below; nil — off).
- **Single page** — `backMirrorOpacity`: how much the page shows through its
  back.

There is no paper color in the configuration — it comes from
`PageCurlHost.paperColor`.

Version 2.0.0 breaks this interface: the curl radii, cone strength and shadow
strength of 1.x are gone; `SpineShadowStyle.strength` is gone too — the
spine's depth is now the leaf shadow's strength; `SpineShadowView` takes the
whole configuration instead of a style. Defaults changed: `duration` 0.45 →
0.75 s (it is also the quiet window), `backMirrorOpacity` 0.22 → 0.5,
`SpineShadowStyle.width` 44 → 32.

On an iPhone with a ProMotion display the curl runs above 60 frames per
second only if the app's `Info.plist` sets
`CADisableMinimumFrameDurationOnPhone` to `true`; an iPad Pro needs no key.
See Apple's [Optimizing iPhone and iPad apps to support ProMotion displays](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays).

Finger tracking (`PageCurlProgressSource.gesture`) is a stub: the entry point
is reserved, the implementation is not there yet.

## The bare effect

The second API layer, for those who need only the render and none of the
conducting. Two same-size snapshots in, a self-driving animation out:

```swift
guard let device = MTLCreateSystemDefaultDevice(),
      let overlay = PageCurlOverlayView(
          device: device,
          currentSpread: currentImage,   // what is on screen now
          targetSpread: targetImage,     // what lies underneath
          sizePoints: container.bounds.size,
          forward: true,
          isSpread: false,               // true — two-page spread, curl half
          paperColor: .white             // the leaf's translucent back
      )
else { return } // no Metal or bad input — show the target instantly instead

overlay.frame = container.bounds
container.addSubview(overlay)
overlay.onFinished = { [weak overlay] in overlay?.removeFromSuperview() }
overlay.start()

// Show the target underneath right after start(): the overlay covers the
// swap, and removing the overlay at any moment is then always safe.
// If the first frame cannot be drawn, start() runs nothing and calls
// onFinished at once, so the target simply appears instantly.
// Here the snapshots are yours: fill their background with the paper color,
// since transparent pixels turn black in the opaque render.
```

## Spine shadow

`SpineShadowView` — the soft band down the middle of a two-page spread, like
the fold of a paper book. Configured by `configuration.spineShadow`
(`SpineShadowStyle`: band width, how much the lamp changes it; nil — off; its
depth at the spine is the leaf shadow's strength): the side turned away from the lamp is a little deeper, the
other a little lighter. The host lays it out on the spread itself, centered on
the spine, full height. The curl leaves it out of its snapshots and draws the
same band itself, on the still pages and on the turning leaf.

```swift
if curl.configuration.spineShadow != nil, isSpread {
    let shadow = SpineShadowView(configuration: curl.configuration)
    shadow.frame = SpineShadowView.frame(
        forSpreadBounds: spreadView.bounds, configuration: curl.configuration
    )
    spreadView.addSubview(shadow)
}
```

## Demo

`Demo/PageCurlKitDemo.xcodeproj` — a booklet of eight static pages: portrait
shows a single page, landscape a two-page spread. A self-contained host of
the protocol and the living code of this recipe.
The gear button opens a tuning panel that writes into the live controller's
configuration.

## License

MIT — see [LICENSE](LICENSE).

If you use PageCurlKit in your app, I'd be glad to hear about it: open an
issue or drop a star.
