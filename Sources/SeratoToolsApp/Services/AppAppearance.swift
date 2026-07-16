import AppKit
import SwiftUI

/// User-selectable appearance for the app.
enum AppTheme: String, CaseIterable, Identifiable {
    var id: String { rawValue }

    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The AppKit appearance to apply, or `nil` to follow the system setting.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Stores and applies the app-wide light/dark/system appearance preference.
@MainActor
final class ThemeController: ObservableObject {
    static let shared = ThemeController()

    private static let defaultsKey = "SeratoToolsAppearance"

    @Published private(set) var current: AppTheme

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        current = raw.flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    /// Applies the currently stored appearance to the running app.
    func applyStored() {
        apply(current.appearance)
    }

    /// Updates the stored preference and applies it immediately.
    func set(_ theme: AppTheme) {
        guard theme != current else { return }
        current = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
        apply(theme.appearance)
    }

    /// Applies an appearance to the app and every window immediately, with no
    /// implicit animation so the switch is instantaneous.
    private func apply(_ appearance: NSAppearance?) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            NSApp.appearance = appearance
            for window in NSApp.windows {
                window.appearance = appearance
            }
        }
    }
}

/// A compact titlebar control placed next to the window's traffic-light buttons
/// that lets the user pick System / Light / Dark appearance.
@MainActor
final class ThemeTitlebarAccessoryController: NSTitlebarAccessoryViewController, NSMenuDelegate {
    private let popUpButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var appearanceObservation: NSKeyValueObservation?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        layoutAttribute = .leading

        popUpButton.pullsDown = true
        popUpButton.bezelStyle = .texturedRounded
        popUpButton.controlSize = .small
        popUpButton.translatesAutoresizingMaskIntoConstraints = false

        let menu = NSMenu()
        menu.delegate = self

        // Item 0 is the always-visible content of a pull-down button: show an icon only.
        let titleItem = NSMenuItem()
        titleItem.image = NSImage(
            systemSymbolName: "circle.lefthalf.filled",
            accessibilityDescription: "Appearance"
        )
        menu.addItem(titleItem)

        for theme in AppTheme.allCases {
            let item = NSMenuItem(
                title: theme.title,
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = theme.rawValue
            menu.addItem(item)
        }

        popUpButton.menu = menu
        popUpButton.toolTip = "Appearance"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 48, height: 28))
        container.addSubview(popUpButton)
        NSLayoutConstraint.activate([
            popUpButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            popUpButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            popUpButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container

        // Live-monitor the resolved appearance so the icon tracks system
        // light/dark switches on the fly (e.g. auto Night Shift schedule).
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    private func updateIcon() {
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let symbol = isDark ? "moon.stars.fill" : "sun.max.fill"
        popUpButton.menu?.items.first?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Appearance"
        )
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let theme = AppTheme(rawValue: raw)
        else { return }
        ThemeController.shared.set(theme)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = ThemeController.shared.current
        for item in menu.items {
            guard let raw = item.representedObject as? String else { continue }
            item.state = (raw == current.rawValue) ? .on : .off
        }
    }
}
