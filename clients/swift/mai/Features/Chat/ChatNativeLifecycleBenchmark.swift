#if os(macOS) && DEBUG
    import AppKit

    extension ChatBenchmarkModel {
        /// Exercises the actual ChatView pagination and width-change paths.
        /// This is a correctness probe, not a frame-rate measurement.
        func runNativeLifecycleBenchmark() async {
            guard let window = Self.appWindow(),
                let scroll = Self.transcriptScrollView(in: window),
                let document = scroll.documentView as? any ChatMacScrollDocument
            else { return }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            ChatBenchmarkAutoRun.trace(
                "lifecycle window fullscreen=\(window.styleMask.contains(.fullScreen)) zoomed=\(window.isZoomed) frame=\(window.frame) min=\(window.minSize) contentMin=\(window.contentMinSize)"
            )
            let wasFullScreen = window.styleMask.contains(.fullScreen)
            if wasFullScreen {
                window.toggleFullScreen(nil)
                let deadline = ContinuousClock.now + .seconds(5)
                while window.styleMask.contains(.fullScreen), ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            defer { if wasFullScreen { window.toggleFullScreen(nil) } }
            let originalFrame = window.frame
            let originalMinSize = window.contentMinSize
            let originalMaxSize = window.contentMaxSize
            defer {
                window.contentMinSize = originalMinSize
                window.contentMaxSize = originalMaxSize
                window.setFrame(originalFrame, display: true)
            }
            let initialRows = document.numberOfRows
            var visible = window.occlusionState.contains(.visible)
            Self.beginSyntheticUserScroll(on: scroll)
            Self.setContentOffsetY(100, on: scroll)
            let oldRow = document.rows(in: scroll.contentView.documentVisibleRect).location
            let anchorID = document.stableIdentity(forRow: oldRow)
            let within = scroll.contentView.bounds.minY - document.rect(ofRow: oldRow).minY
            Self.endSyntheticUserScroll(on: scroll)
            let deadline = ContinuousClock.now + .seconds(30)
            while document.numberOfRows <= initialRows, ContinuousClock.now < deadline {
                visible = visible && window.occlusionState.contains(.visible)
                try? await Task.sleep(for: .milliseconds(25))
            }
            await waitForStableGeometry(document: document, scroll: scroll)
            let paginatedRows = document.numberOfRows
            let paginationError = anchorError(
                document: document, scroll: scroll, id: anchorID, within: within)

            // Put the viewport away from the history trigger before reflowing.
            Self.beginSyntheticUserScroll(on: scroll)
            Self.setContentOffsetY(document.bounds.height / 2, on: scroll)
            Self.endSyntheticUserScroll(on: scroll)
            await waitForStableGeometry(document: document, scroll: scroll)
            let resizeRow = document.rows(in: scroll.contentView.documentVisibleRect).location
            let resizeID = document.stableIdentity(forRow: resizeRow)
            let resizeWithin = scroll.contentView.bounds.minY - document.rect(ofRow: resizeRow).minY
            let priorHeight = document.bounds.height
            var narrowFrame = originalFrame
            window.contentMinSize = NSSize(width: 600, height: 400)
            window.contentMaxSize = NSSize(width: 2000, height: 2000)
            narrowFrame.size.width = 700
            if window.isZoomed {
                window.zoom(nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
            window.setFrame(narrowFrame, display: true, animate: true)
            try? await Task.sleep(for: .seconds(1))
            await waitForStableGeometry(document: document, scroll: scroll)
            visible = visible && window.occlusionState.contains(.visible)
            let resizeError = anchorError(
                document: document, scroll: scroll, id: resizeID, within: resizeWithin)
            let report: [String: Any] = [
                "label": "native-pagination-resize", "measurementKind": "lifecycleCorrectness",
                "initialRows": initialRows, "paginatedRows": paginatedRows,
                "paginationAnchorErrorPoints": paginationError,
                "resizeAnchorErrorPoints": resizeError,
                "resizeAnchorID": resizeID ?? "missing",
                "resizeOffsetWithinRowBefore": resizeWithin,
                "resizeOffsetWithinRowAfter": resizeID.flatMap {
                    document.row(forStableIdentity: $0)
                }.map { scroll.contentView.bounds.minY - document.rect(ofRow: $0).minY } ?? -1,
                "resizeAnchorHeightAfter": resizeID.flatMap { document.row(forStableIdentity: $0) }
                    .map { document.rect(ofRow: $0).height } ?? -1,
                "windowWidthAfterResize": window.frame.width,
                "viewportWidthAfterResize": scroll.contentSize.width,
                "heightBeforeResize": priorHeight, "heightAfterResize": document.bounds.height,
                "visible": visible,
                "passed": visible && paginatedRows > initialRows && paginationError <= 1
                    && resizeError <= 1
                    && priorHeight != document.bounds.height,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.sortedKeys]),
                let json = String(data: data, encoding: .utf8)
            {
                print("CHAT_BENCHMARK_RESULT \(json)")
            }
        }

        private func anchorError(
            document: any ChatMacScrollDocument, scroll: NSScrollView,
            id: String?, within: CGFloat
        ) -> CGFloat {
            guard let id, let index = document.row(forStableIdentity: id) else {
                return .greatestFiniteMagnitude
            }
            let rect = document.rect(ofRow: index)
            return abs(scroll.contentView.bounds.minY - (rect.minY + min(within, rect.height)))
        }

        private func waitForStableGeometry(
            document: any ChatMacScrollDocument, scroll: NSScrollView
        ) async {
            let deadline = ContinuousClock.now + .seconds(30)
            var previous = CGRect.null
            var stableSince = ContinuousClock.now
            while ContinuousClock.now < deadline {
                let state = CGRect(
                    x: scroll.contentView.bounds.minY, y: document.bounds.height,
                    width: scroll.contentSize.width, height: CGFloat(document.numberOfRows))
                if state != previous || !ChatBenchmarkAutoRun.isNativeGeometryWarm {
                    previous = state
                    stableSince = .now
                } else if stableSince.duration(to: .now) >= .milliseconds(500) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }
#endif
