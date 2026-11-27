import SwiftUI
import UIKit
import ImageIO

/// Animated-GIF playback without any third-party dependency: frames
/// and delays are pulled out of the GIF with ImageIO and handed to
/// UIImageView's built-in animation. When `animating` is false the
/// first frame is shown as a still (Reduce Motion).
private struct GIFImageView: UIViewRepresentable {
    let data: Data
    var animating: Bool = true

    /// Decoded-frame cache: the walking view re-renders on every
    /// TimelineView tick, and re-decoding the GIF each time would
    /// burn CPU and restart the frame animation. Keyed by the data
    /// itself (the pet GIFs are small and few).
    private static var frameCache: [Data: (images: [UIImage], duration: TimeInterval)] = [:]

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = false
        configure(view)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        configure(view)
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: ()) {
        view.stopAnimating()
        view.animationImages = nil
    }

    private func configure(_ view: UIImageView) {
        let frames: (images: [UIImage], duration: TimeInterval)
        if let cached = Self.frameCache[data] {
            frames = cached
        } else {
            frames = Self.frames(from: data)
            Self.frameCache[data] = frames
        }
        guard let first = frames.images.first else { return }
        if animating, frames.images.count > 1 {
            if view.animationImages == nil {
                view.animationImages = frames.images
                view.animationDuration = frames.duration
                view.animationRepeatCount = 0
            }
            if !view.isAnimating { view.startAnimating() }
        } else {
            view.stopAnimating()
            view.animationImages = nil
            view.image = first
        }
    }

    static func frames(from data: Data) -> (images: [UIImage], duration: TimeInterval) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return ([], 0)
        }
        let count = CGImageSourceGetCount(source)
        var images: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            images.append(UIImage(cgImage: cg))
            duration += delay(of: source, at: index)
        }
        if duration <= 0 { duration = Double(max(images.count, 1)) * 0.1 }
        return (images, duration)
    }

    private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [String: Any],
              let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        else { return 0.1 }
        let value = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime as String] as? Double)
            ?? 0.1
        // Browsers clamp very short delays to ~100ms; mirror that so
        // an asset authored at 20ms does not turn into a blur.
        return value < 0.02 ? 0.1 : value
    }
}

/// The start page's walking pet (v0.4.9, item 9): a small animal
/// strolling slowly along the bottom edge, turning around at both
/// ends. Pure decoration — hit testing is disabled, it only exists
/// on the start page, and it carries no user data (it also shows on
/// private tabs). The artwork is bundled external material (see
/// PetAssets for sources/licenses); nothing is drawn in code.
///
/// Motion: the GIF itself animates the legs. This view only moves
/// the animal across the width at ~30pt/s with a tiny bob; the
/// penguin additionally rocks a few degrees (a waddle, since its
/// asset is an idle loop). With Reduce Motion on, the animal stands
/// still at the left end as a still image.
struct WalkingPetView: View {
    let pet: HomePet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let size = displaySize
            if let data = PetAssets.gifData(for: pet) {
                if reduceMotion {
                    GIFImageView(data: data, animating: false)
                        .frame(width: size.width, height: size.height)
                        .position(x: size.width / 2 + 16, y: size.height / 2)
                } else {
                    TimelineView(.animation(paused: scenePhase != .active)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let placement = placement(at: t, width: width, petWidth: size.width)
                        GIFImageView(data: data, animating: scenePhase == .active)
                            .frame(width: size.width, height: size.height)
                            .scaleEffect(x: placement.facing, y: 1)
                            .rotationEffect(.degrees(placement.rock))
                            .position(x: placement.x, y: size.height / 2 + placement.bob)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Per-pet display size: heights stay in the modest 44–54pt band
    /// from the spec; widths follow each GIF's real aspect ratio.
    private var displaySize: CGSize {
        switch pet {
        case .cat: return CGSize(width: 46, height: 46)        // 64×64
        case .dog: return CGSize(width: 72, height: 44)        // 112×68
        case .duck: return CGSize(width: 54, height: 52)       // 227×217
        case .penguin: return CGSize(width: 47, height: 54)    // 228×264
        case .none: return .zero
        }
    }

    /// Ping-pong placement: walks right, flips at the edge, walks
    /// back. `facing` is +1 in the asset's native direction (all
    /// assets face right) and −1 mirrored on the return leg.
    private func placement(at t: TimeInterval, width: CGFloat, petWidth: CGFloat)
        -> (x: CGFloat, facing: CGFloat, bob: CGFloat, rock: Double) {
        let speed: CGFloat = 30
        let travel = max(width + petWidth, 1)
        let phase = CGFloat(t) * speed
        let cycle = phase.truncatingRemainder(dividingBy: 2 * travel)
        let x: CGFloat
        let facing: CGFloat
        if cycle < travel {
            x = -petWidth / 2 + cycle
            facing = 1
        } else {
            x = width + petWidth / 2 - (cycle - travel)
            facing = -1
        }
        // A gentle bob synced loosely to a step rhythm, plus the
        // penguin's waddle rock. Everything stays slow and small.
        let bob = CGFloat(sin(t * 2 * Double.pi / 0.9)) * 1.5
        let rock = pet == .penguin ? sin(t * 2 * Double.pi / 0.8) * 3.0 : 0
        return (x, facing, bob, rock)
    }
}
