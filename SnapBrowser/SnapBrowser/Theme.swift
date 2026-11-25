import SwiftUI
import UIKit

/// Design system shared with the Android version:
/// Paper #F7F5F0 / Ink #1A1C20 / Cobalt #2F4BFF / Shutter red #FF4D2E.
/// Red is used ONLY as the tiny centre dot of the SNAP aperture icon.
/// No floating pill bars, no protruding buttons, no big solid-red circles.
enum Theme {
    static let cobalt = Color(red: 0x2F / 255.0, green: 0x4B / 255.0, blue: 0xFF / 255.0)
    static let shutterRed = Color(red: 0xFF / 255.0, green: 0x4D / 255.0, blue: 0x2E / 255.0)

    static let paper = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
            : UIColor(red: 0xF7 / 255.0, green: 0xF5 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
    })

    static let surface = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
            : UIColor(white: 1.0, alpha: 1)
    })

    static let ink = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.91, green: 0.92, blue: 0.93, alpha: 1)
            : UIColor(red: 0x1A / 255.0, green: 0x1C / 255.0, blue: 0x20 / 255.0, alpha: 1)
    })

    static let hairline = Color(UIColor.separator)
}

/// SNAP aperture: line icon with a tiny red centre dot (the only red allowed).
struct ApertureIcon: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Image(systemName: "camera.aperture")
                .font(.system(size: size))
            Circle()
                .fill(Theme.shutterRed)
                .frame(width: size * 0.22, height: size * 0.22)
        }
    }
}

/// Round letter tile used for tabs / history / shortcuts when no favicon
/// is available (first letter of the title or host, cobalt-tinted).
struct LetterAvatar: View {
    let text: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Theme.cobalt.opacity(0.15))
            Text(letter)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Theme.cobalt)
        }
        .frame(width: size, height: size)
    }

    private var letter: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

enum DateFormatters {
    /// "11/25 20:41" — same shape as the Android 保存版 banner.
    static let banner: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    /// "2026年11月25日" for history day headers.
    static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()
}
