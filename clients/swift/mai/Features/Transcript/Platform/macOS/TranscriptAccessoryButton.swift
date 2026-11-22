#if os(macOS)
    import AppKit

    /// A row's native control (`RowAccessory`), pooled by the transcript
    /// document: copy buttons show "Copied" for a moment, as the chat's other
    /// copy buttons do; the fork button opens the turn's fork menu.
    final class TranscriptAccessoryButton: NSButton {
        private(set) var accessory: RowAccessory.Action?
        /// Opens turn `turnID`'s fork menu from this button.
        var onFork: ((String, NSButton) -> Void)?
        private var resetTask: Task<Void, Never>?
        /// The symbol and label shown: a streamed code block's copy text
        /// changes every frame, its symbol does not.
        private var shown: (symbol: String, label: String)?

        private static let copyImage = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
        private static let copiedImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        private static let forkImage = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)

        func matchesKind(of action: RowAccessory.Action) -> Bool {
            switch action {
            case .copy: shown?.symbol == "square.on.square"
            case .fork: shown?.symbol == "arrow.triangle.branch"
            }
        }

        init() {
            super.init(frame: .zero)
            isBordered = false
            imagePosition = .imageOnly
            imageScaling = .scaleNone
            contentTintColor = .secondaryLabelColor
            symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            target = self
            action = #selector(press)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func show(_ accessory: RowAccessory.Action) {
            guard accessory != self.accessory else { return }
            self.accessory = accessory
            // Still "Copied" for the same block whose text grew.
            if resetTask == nil { showCopied(false) }
        }

        func resetForReuse() {
            accessory = nil
            resetTask?.cancel()
            resetTask = nil
            onFork = nil
        }

        @objc private func press() {
            switch accessory {
            case .copy(let text, _):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showCopied(true)
                resetTask?.cancel()
                resetTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self?.resetTask = nil
                    self?.showCopied(false)
                }
            case .fork(let turnID):
                onFork?(turnID, self)
            case nil:
                break
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
                image =
                    switch symbol {
                    case "square.on.square": Self.copyImage
                    case "checkmark": Self.copiedImage
                    case "arrow.triangle.branch": Self.forkImage
                    default: NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                    }
            }
            shown = (symbol, label)
            toolTip = label
            setAccessibilityLabel(label)
        }
    }
#endif
