import Foundation

/// What the transcript needs of one entry, copied out of `EntryView` so the
/// controller never holds the store's turns: sharing that buffer would make
/// the store copy every turn on the next streamed chunk.
nonisolated struct TranscriptEntry: Sendable {
    let ref: String
    let kind: MaidItemKind?
    let text: String
    let title: String?
    let envelopeKind: MaidEnvelopeKind?
    let envelopeFrom: String?
    let envelopeBody: String?
    /// The verb this entry adds to its activity group's summary.
    let activityPhrase: TranscriptActivityPhrase
    let isRunningInBackground: Bool
    let hasRequestRecord: Bool

    init(_ entry: EntryView) {
        ref = entry.ref
        kind = entry.itemKind
        text = entry.text ?? ""
        title = entry.title
        envelopeKind = entry.envelopeKind
        envelopeFrom = entry.envelope?.from
        envelopeBody = entry.envelope?.body
        activityPhrase = TranscriptActivityPhrase(entry)
        isRunningInBackground = entry.itemStatus == .inProgress && entry.tool?.background == true
        hasRequestRecord = entry.request != nil
    }
}
