#if os(iOS)
    import UIKit

    /// A row's native control (`RowAccessory`), pooled by the transcript:
    /// copy buttons show "Copied" for a moment, as the chat's other copy
    /// buttons do; the fork button opens the turn's fork menu as its primary
    /// action.
    final class TranscriptAccessoryControl: UIButton {
        private enum Icon {
            case copy, copied, fork

            private static let copyImage = UIImage(systemName: "square.on.square")
            private static let copiedImage = UIImage(systemName: "checkmark")
            private static let forkImage = UIImage(systemName: "arrow.triangle.branch")

            var image: UIImage? {
                switch self {
                case .copy: Self.copyImage
                case .copied: Self.copiedImage
                case .fork: Self.forkImage
                }
            }
        }

        private(set) var accessory: RowAccessory.Action?
        private var resolveCopy: ((RowAccessory.Action) -> String)?
        private var resetTask: Task<Void, Never>?
        /// The icon and label shown: a streamed code block's copy text
        /// changes every frame, its icon does not.
        private var shown: (icon: Icon, label: String)?

        /// Whether this pooled control already shows the icon for `action`,
        /// avoiding a `UIButton.Configuration` rebuild on reuse.
        func matchesKind(of action: RowAccessory.Action) -> Bool {
            switch action {
            case .copy, .copyReply: shown?.icon == .copy
            case .fork: shown?.icon == .fork
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
        func show(
            _ accessory: RowAccessory.Action,
            resolveCopy: @escaping (RowAccessory.Action) -> String,
            forkMenu: @escaping (String) -> TranscriptMenu?
        ) {
            self.resolveCopy = resolveCopy
            guard accessory != self.accessory else { return }
            // A copy button whose text changed keeps its (empty) menu.
            let wasCopy = Self.isCopyAction(self.accessory)
            self.accessory = accessory
            // Still "Copied" for the same block whose text grew.
            if resetTask == nil { showCopied(false) }
            if Self.isCopyAction(accessory), wasCopy { return }
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

        private static func isCopyAction(_ action: RowAccessory.Action?) -> Bool {
            switch action {
            case .copy, .copyReply: true
            case .fork, nil: false
            }
        }

        func resetForReuse() {
            accessory = nil
            resolveCopy = nil
            resetTask?.cancel()
            resetTask = nil
            menu = nil
        }

        private func press() {
            guard let accessory, Self.isCopyAction(accessory) else { return }
            let text: String
            switch accessory {
            case .copy(let value, _): text = value
            case .copyReply: text = resolveCopy?(accessory) ?? ""
            case .fork: return
            }
            guard !text.isEmpty else { return }
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
            let (icon, label): (Icon, String) =
                switch accessory {
                case .copy(_, let label): copied ? (.copied, "Copied") : (.copy, label)
                case .copyReply: copied ? (.copied, "Copied") : (.copy, "Copy reply")
                case .fork: (.fork, "Fork from this turn")
                case nil: (.copy, "")
                }
            guard shown?.icon != icon || shown?.label != label else { return }
            if shown?.icon != icon { configuration?.image = icon.image }
            shown = (icon, label)
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
