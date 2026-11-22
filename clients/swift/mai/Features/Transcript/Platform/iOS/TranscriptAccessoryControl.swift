#if os(iOS)
    import UIKit

    /// A row's native control (`RowAccessory`), pooled by the transcript:
    /// copy buttons show "Copied" for a moment, as the chat's other copy
    /// buttons do; the fork button opens the turn's fork menu as its primary
    /// action.
    final class TranscriptAccessoryControl: UIButton {
        private(set) var accessory: RowAccessory.Action?
        private var resetTask: Task<Void, Never>?
        /// The symbol and label shown: a streamed code block's copy text
        /// changes every frame, its symbol does not.
        private var shown: (symbol: String, label: String)?

        private static let copyImage = UIImage(systemName: "square.on.square")
        private static let copiedImage = UIImage(systemName: "checkmark")
        private static let forkImage = UIImage(systemName: "arrow.triangle.branch")

        /// Whether this pooled control already shows the symbol for `action`,
        /// avoiding a `UIButton.Configuration` rebuild on reuse.
        func matchesKind(of action: RowAccessory.Action) -> Bool {
            switch action {
            case .copy: shown?.symbol == "square.on.square"
            case .fork: shown?.symbol == "arrow.triangle.branch"
            }
        }

        init() {
            super.init(frame: .zero)
            var configuration = UIButton.Configuration.plain()
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption1)
            configuration.baseForegroundColor = .secondaryLabel
            self.configuration = configuration
            addAction(UIAction { [weak self] _ in self?.press() }, for: .primaryActionTriggered)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Shows `accessory`; `forkMenu` gives a fork button its menu when
        /// opened, so the menu reflects the chat as it is then.
        func show(_ accessory: RowAccessory.Action, forkMenu: @escaping (String) -> TranscriptMenu?) {
            guard accessory != self.accessory else { return }
            // A copy button whose text changed keeps its (empty) menu.
            var wasCopy = false
            if case .copy = self.accessory { wasCopy = true }
            self.accessory = accessory
            // Still "Copied" for the same block whose text grew.
            if resetTask == nil { showCopied(false) }
            if case .copy = accessory, wasCopy { return }
            if case .fork(let turnID) = accessory {
                menu = UIMenu(children: [
                    UIDeferredMenuElement.uncached { completion in
                        completion(forkMenu(turnID).map(UIMenu.elements(of:)) ?? [])
                    }
                ])
                showsMenuAsPrimaryAction = true
            } else {
                menu = nil
                showsMenuAsPrimaryAction = false
            }
        }

        func resetForReuse() {
            accessory = nil
            resetTask?.cancel()
            resetTask = nil
            menu = nil
        }

        private func press() {
            guard case .copy(let text, _) = accessory else { return }
            UIPasteboard.general.string = text
            showCopied(true)
            resetTask?.cancel()
            resetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.resetTask = nil
                self?.showCopied(false)
            }
        }

        private func showCopied(_ copied: Bool) {
            let (symbol, label): (String, String) =
                switch accessory {
                case .copy(_, let label): copied ? ("checkmark", "Copied") : ("square.on.square", label)
                case .fork: ("arrow.triangle.branch", "Fork from this turn")
                case nil: ("square.on.square", "")
                }
            guard shown?.symbol != symbol || shown?.label != label else { return }
            if shown?.symbol != symbol {
                configuration?.image =
                    switch symbol {
                    case "square.on.square": Self.copyImage
                    case "checkmark": Self.copiedImage
                    case "arrow.triangle.branch": Self.forkImage
                    default: UIImage(systemName: symbol)
                    }
            }
            shown = (symbol, label)
            accessibilityLabel = label
        }
    }

    extension UIMenu {
        /// The platform menu elements for a row's menu.
        static func elements(of menu: TranscriptMenu) -> [UIMenuElement] {
            menu.items.map(element(_:))
        }

        private static func element(_ item: TranscriptMenu.Item) -> UIMenuElement {
            let image = item.systemImage.flatMap { UIImage(systemName: $0) }
            if !item.children.isEmpty {
                return UIMenu(title: item.title, image: image, children: item.children.map(element(_:)))
            }
            let action = item.action
            return UIAction(title: item.title, image: image) { _ in action?() }
        }
    }
#endif
