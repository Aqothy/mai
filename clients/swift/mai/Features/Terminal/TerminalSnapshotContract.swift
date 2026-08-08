/// Native Ghostty snapshot compatibility shared with the daemon build.
enum TerminalSnapshotContract {
    /// GHOSTSNP v1 is not stable across arbitrary Ghostty commits, so both
    /// processes must advertise the exact core revision they embed.
    static let format = "ghostty-gsn-v1-7a9c369cf5da72d41946f683c48b0466a210cb7e"
}
