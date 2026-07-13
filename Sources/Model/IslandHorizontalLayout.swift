import Foundation

/// Pure horizontal geometry for the notch-aligned compact states. Claude has
/// three persistent metrics while Codex currently has one, so equal rails
/// waste a large blank region. The center offset keeps the hardware notch at
/// screen center while the silhouette grows by exactly what each side needs.
struct IslandHorizontalLayout {
    let notchWidth: CGFloat
    let tabWidth: CGFloat
    let claudeRailWidth: CGFloat
    let codexRailWidth: CGFloat

    var compactWidth: CGFloat {
        notchWidth + tabWidth * 2
    }

    var leftPeekWidth: CGFloat {
        tabWidth + claudeRailWidth
    }

    var rightPeekWidth: CGFloat {
        tabWidth + codexRailWidth
    }

    var peekWidth: CGFloat {
        leftPeekWidth + notchWidth + rightPeekWidth
    }

    /// Offset of the silhouette's center from the screen/notch center.
    /// A wider Claude side shifts the silhouette left while the notch itself
    /// remains stationary.
    var peekCenterOffset: CGFloat {
        (rightPeekWidth - leftPeekWidth) / 2
    }
}
