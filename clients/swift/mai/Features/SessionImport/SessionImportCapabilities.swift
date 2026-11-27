struct SessionImportCapabilities: Equatable {
    let canImport: Bool
    let canDelete: Bool

    static let unavailable = SessionImportCapabilities(
        canImport: false,
        canDelete: false
    )
}
