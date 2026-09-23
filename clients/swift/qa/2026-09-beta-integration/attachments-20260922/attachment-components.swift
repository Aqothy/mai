// Run in ComposerAttachments.swift's context with Xcode RunCodeSnippet on My Mac.
// QA_OUTPUT must be a fresh app-container temporary directory with the fixtures.
let output = URL(fileURLWithPath: "QA_OUTPUT")
@MainActor struct AttachmentQARoot: View {
    let attachments: [Attachment]
    var textSize: DynamicTypeSize = .large
    var body: some View {
        VStack {
            ChatMessageAttachmentsView(attachments: attachments)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .environment(\.dynamicTypeSize, textSize)
    }
}
let host = NSHostingView(rootView: AttachmentQARoot(attachments: []))
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "mai attachment QA"
window.contentView = host
window.orderFront(nil)
defer { window.orderOut(nil); window.close() }
var results: [[String: Any]] = []
@MainActor func capture(_ name: String) throws -> [String: Any] {
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "AttachmentQA", code: 1) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "AttachmentQA", code: 2) }
    try data.write(to: output.appending(path: name + ".png"))
    var red = 0, blue = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.alphaComponent > 0.9 && c.redComponent > 0.65 && c.blueComponent < 0.35 { red += 1 }
            if c.alphaComponent > 0.9 && c.blueComponent > 0.65 && c.redComponent < 0.35 { blue += 1 }
        }
    }
    return ["name": name, "redSamples": red, "blueSamples": blue, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "AttachmentQA", code: 3, userInfo: [NSLocalizedDescriptionKey: message]) }
}
do {
    let red = try Data(contentsOf: output.appending(path: "red.png")).base64EncodedString()
    let blue = try Data(contentsOf: output.appending(path: "blue.png")).base64EncodedString()
    for (name, payload, expectedColor) in [
        ("01-red", red, "red"), ("02-blue-same-view", blue, "blue"),
        ("03-invalid-same-view", "not an image", "none"),
        ("04-oversized-same-view", String(repeating: "A", count: ChatTranscriptImageDecoder.maximumEncodedCharacterCount + 1), "none"),
        ("05-red-recovered-same-view", red, "red")
    ] {
        host.rootView = AttachmentQARoot(attachments: [Attachment(data: payload, kind: "image", mimeType: "image/png", name: "QA image", uri: nil)])
        try await Task.sleep(for: .seconds(1))
        let result = try capture(name)
        let reds = result["redSamples"] as! Int, blues = result["blueSamples"] as! Int
        if expectedColor == "red" { try require(reds > 1000 && blues == 0, "Red image missing or stale blue pixels") }
        if expectedColor == "blue" { try require(blues > 1000 && reds == 0, "Blue replacement missing or stale red pixels") }
        if expectedColor == "none" { try require(reds == 0 && blues == 0, "Invalid payload retained old image pixels") }
        results.append(result)
    }
    host.rootView = AttachmentQARoot(attachments: [
        Attachment(data: nil, kind: "image", mimeType: "image/png", name: "Missing image", uri: nil),
        Attachment(data: nil, kind: "image", mimeType: "image/png", name: "Remote image link", uri: "https://example.com/qa.png"),
        Attachment(data: nil, kind: "audio", mimeType: "audio/wav", name: "Unsupported inline audio", uri: nil)
    ])
    try await Task.sleep(for: .milliseconds(500))
    results.append(try capture("06-missing-remote-other"))

    for (name, width, appearance, textSize) in [
        ("07-fallback-light", 640.0, NSAppearance.Name.aqua, DynamicTypeSize.large),
        ("08-fallback-narrow", 240.0, NSAppearance.Name.darkAqua, DynamicTypeSize.large),
        ("09-fallback-narrow-large-text", 240.0, NSAppearance.Name.darkAqua, DynamicTypeSize.accessibility3),
        ("10-fallback-grid-large-text", 375.0, NSAppearance.Name.aqua, DynamicTypeSize.accessibility3)
    ] {
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: width, height: 560))
        let invalid = Attachment(data: "not an image", kind: "image", mimeType: "image/png", name: "QA unavailable image", uri: nil)
        host.rootView = AttachmentQARoot(attachments: name.contains("grid") ? [invalid, invalid] : [invalid], textSize: textSize)
        try await Task.sleep(for: .seconds(1))
        results.append(try capture(name))
    }

    var errors: [String] = []
    let composer = ComposerAttachmentsModel()
    composer.reportError = { errors.append($0) }
    await composer.addImages(from: Array(repeating: output.appending(path: "red.png"), count: 9))
    try require(composer.attachments.count == 8 && errors.count == 1, "Attachment count limit failed")
    let removedID = composer.attachments[0].id
    composer.remove(id: removedID)
    let deadline = Date().addingTimeInterval(10)
    while composer.attachments.contains(where: \.isProcessing) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(composer.attachments.count == 7 && !composer.attachments.contains(where: \.isProcessing), "Removed or unprocessed attachment remained")
    try require(!composer.attachments.contains(where: { $0.id == removedID }), "Late processing restored a removed attachment")
    try require(composer.attachments.allSatisfy { $0.attachment?.data == red && $0.attachment?.mimeType == "image/png" }, "File upload changed image bytes or MIME type")
    results.append(["name": "composer-limit-removal-pipeline", "ready": composer.attachments.count, "limitErrors": errors.count, "passed": true])
    for name in ["invalid.png", "empty.png", "unsupported.txt", "oversized.png"] {
        let model = ComposerAttachmentsModel()
        var failures: [String] = []
        model.reportError = { failures.append($0) }
        await model.addImages(from: [output.appending(path: name)])
        let deadline = Date().addingTimeInterval(10)
        while failures.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(model.attachments.isEmpty && failures.count == 1, "Invalid composer file not rejected: " + name)
        results.append(["name": name, "error": failures[0], "passed": true])
    }
    let unsupported = ComposerAttachmentsModel()
    unsupported.canAttachImages = { false }
    var unsupportedErrors: [String] = []
    unsupported.reportError = { unsupportedErrors.append($0) }
    await unsupported.addImages(from: [output.appending(path: "red.png")])
    try require(unsupported.attachments.isEmpty && unsupportedErrors.count == 1, "Unsupported provider accepted an image")
    results.append(["name": "provider-capability-gate", "passed": true])
    print("PASS: image replacement/fallback rendering and composer file pipeline")
} catch {
    results.append(["failure": String(describing: error)])
    print("FAIL: \(error)")
}
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "results.json"))
