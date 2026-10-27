import Foundation

/// Typed views over the generated models' open `String` fields.
///
/// Those fields stay `String` so a value from a newer daemon still decodes.
/// These accessors return `nil` for exactly that case: branch on the enum and
/// treat `nil` as "unrecognized — ignore".
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
