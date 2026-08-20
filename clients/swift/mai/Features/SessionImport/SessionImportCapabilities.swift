struct SessionImportCapabilities: Equatable {
    let canImport: Bool
    let canClose: Bool
    let canDelete: Bool

    static let unavailable = SessionImportCapabilities(
        canImport: false,
        canClose: false,
        canDelete: false
    )
}
