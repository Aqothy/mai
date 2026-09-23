let output = URL(fileURLWithPath: "QA_OUTPUT")
var results: [[String: Any]] = []
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "AttachmentLimitsQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
for name in ["valid-boundary.png", "valid-oversized.png", "disguised.txt"] {
    let url = output.appending(path: name)
    _ = try await ChatAttachmentLoader.loadThumbnail(from: url)
    let model = ComposerAttachmentsModel()
    var errors: [String] = []
    model.reportError = { errors.append($0) }
    await model.addImages(from: [url])
    let deadline = Date().addingTimeInterval(10)
    while model.attachments.contains(where: \.isProcessing) && errors.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let bytes = try Data(contentsOf: url)
    if name == "valid-boundary.png" {
        try require(errors.isEmpty && model.attachments.count == 1 && model.attachments[0].attachment?.data == bytes.base64EncodedString(), "Exactly 10 MiB image failed")
        let decoded = try await ChatTranscriptImageDecoder.decodeBase64(bytes.base64EncodedString())
        try require(decoded.cgImage.width == 8 && decoded.cgImage.height == 8, "Boundary image did not decode")
        results.append(["name": name, "bytes": bytes.count, "thumbnailDecoded": true, "passed": true, "result": "Exact upload and transcript decode"])
    } else {
        try require(model.attachments.isEmpty && errors.count == 1, "Expected one rejection")
        try require(name == "valid-oversized.png" ? errors[0].contains("10 MB image limit") : errors[0].contains("not a supported image"), "Wrong rejection: " + errors[0])
        if name == "valid-oversized.png" {
            do {
                _ = try await ChatTranscriptImageDecoder.decodeBase64(bytes.base64EncodedString())
                throw NSError(domain: "AttachmentLimitsQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transcript accepted oversized data"])
            } catch let error as ChatTranscriptImageLoadingError {
                try require(error == .imageDataTooLarge, "Wrong transcript rejection")
            }
        }
        results.append(["name": name, "bytes": bytes.count, "thumbnailDecoded": true, "passed": true, "error": errors[0]])
    }
}
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "results.json"))
print("PASS: decodable image accepted at 10 MiB, rejected at 10 MiB + 1; image with unsupported file type rejected")
