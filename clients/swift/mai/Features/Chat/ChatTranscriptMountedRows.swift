/// How both platforms' transcript documents carry their mounted row views
/// through an install that may reorder, add or remove rows.
enum ChatTranscriptMountedRows {
    /// The mounted views an install keeps, by their rows' new indices. A
    /// row whose inputs changed is refreshed in place, or swapped for a view
    /// of its new kind. A view whose row left, or whose row another view
    /// already holds (a duplicate ID), is recycled.
    static func retained<Host: AnyObject>(
        _ hosts: [Int: Host], oldIDs: [String], in geometry: ChatVirtualTranscriptGeometry,
        changedIDs: Set<String>?,
        configure: (_ index: Int, _ current: Host) -> Host,
        recycle: (Host) -> Void,
        show: (Host) -> Void
    ) -> [Int: Host] {
        var retained: [Int: Host] = [:]
        retained.reserveCapacity(hosts.count)
        for (oldIndex, host) in hosts {
            let id = oldIDs[oldIndex]
            guard let index = geometry.index(for: id), retained[index] == nil else {
                recycle(host)
                continue
            }
            let updated = changedIDs?.contains(id) == false ? host : configure(index, host)
            if updated !== host {
                recycle(host)
                show(updated)
            }
            retained[index] = updated
        }
        return retained
    }

    /// The view for a row: its current view refreshed in place while that
    /// is still the row's kind, otherwise a pooled view of the new kind.
    /// Pools are split by kind: a hosting view cannot become a native row,
    /// so a mixed pool would hand over the wrong kind about half the time.
    static func configuredHost<Host: AnyObject>(
        _ index: Int, current: Host?,
        isHosting: (Host) -> Bool,
        nativePool: inout [Host], hostingPool: inout [Host],
        nativeRow: (_ index: Int, _ reused: Host?) -> Host?,
        hostingRow: (_ index: Int, _ reused: Host?) -> Host
    ) -> Host {
        let isHosted = current.map(isHosting) ?? false
        let candidate = isHosted ? nativePool.last : current ?? nativePool.last
        if let native = nativeRow(index, candidate) {
            if native === candidate, native !== current {
                nativePool.removeLast()
            }
            return native
        }
        return hostingRow(index, isHosted ? current : hostingPool.popLast())
    }
}
