import Foundation

/// Typed views over the generated models' open `String` fields.
///
/// Those fields stay `String` so a value from a newer daemon still decodes.
/// These accessors return `nil` for exactly that case: branch on the enum and
/// treat `nil` as "unrecognized — ignore".
extension Event {
    var eventType: MaidEventType? { MaidEventType(rawValue: type) }
}

extension Turn {
    var turnState: MaidTurnState? { MaidTurnState(rawValue: state) }
}

extension SessionBinding {
    var sessionStatus: MaidSessionStatus? { MaidSessionStatus(rawValue: status) }
}

extension Approval {
    var approvalStatus: MaidApprovalStatus? { MaidApprovalStatus(rawValue: status) }
}

extension Item {
    var itemKind: MaidItemKind? { MaidItemKind(rawValue: kind) }
    var itemStatus: MaidItemStatus? { MaidItemStatus(rawValue: status) }
}

extension TimelineEntry {
    var entryKind: MaidTimelineEntryKind? { MaidTimelineEntryKind(rawValue: kind) }
}

extension ThreadStreamItem {
    var streamKind: MaidStreamItemKind? { MaidStreamItemKind(rawValue: kind) }
}

extension ThreadListStreamItem {
    var streamKind: MaidStreamItemKind? { MaidStreamItemKind(rawValue: kind) }
}

extension ConfigOption {
    var optionType: MaidConfigOptionType? { MaidConfigOptionType(rawValue: type) }
    var optionCategory: MaidConfigOptionCategory? { category.flatMap(MaidConfigOptionCategory.init) }

    var selectedChoiceLabel: String? {
        guard let currentValue = currentValue?.value as? String else { return nil }
        return choices?.first { $0.value == currentValue }?.label ?? currentValue
    }
}

extension InstanceInfo {
    var instanceStatus: MaidInstanceStatus? { MaidInstanceStatus(rawValue: status) }
}
