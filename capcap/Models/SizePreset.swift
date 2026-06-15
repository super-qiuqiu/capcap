import Foundation

/// A screenshot size preset that constrains the selection area.
struct SizePreset: Codable, Identifiable, Equatable {
    static let maxCustomPresetCount = 20

    let id: UUID
    var name: String
    var constraint: SizeConstraint
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, constraint: SizeConstraint, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.constraint = constraint
        self.isBuiltIn = isBuiltIn
    }

    /// Built-in presets available on first launch.
    ///
    /// Keep IDs stable. `activeSizePresetID` is persisted separately, so
    /// regenerated UUIDs would make an active built-in preset disappear after
    /// relaunch.
    static let builtInPresets: [SizePreset] = [
        SizePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001080")!,
            name: "1920×1080",
            constraint: .fixedSize(width: 1920, height: 1080),
            isBuiltIn: true
        ),
        SizePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000169")!,
            name: "16:9",
            constraint: .aspectRatio(width: 16, height: 9),
            isBuiltIn: true
        ),
        SizePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            name: "4:3",
            constraint: .aspectRatio(width: 4, height: 3),
            isBuiltIn: true
        )
    ]

    static var builtInPresetIDs: Set<UUID> {
        Set(builtInPresets.map(\.id))
    }

    static func normalized(_ presets: [SizePreset], deletedBuiltInIDs: Set<UUID> = []) -> [SizePreset] {
        let builtInIDs = Set(builtInPresets.map(\.id))
        let visibleBuiltIns = builtInPresets.filter { !deletedBuiltInIDs.contains($0.id) }
        let custom = presets
            .filter { !$0.isBuiltIn && !builtInIDs.contains($0.id) }
            .compactMap { preset -> SizePreset? in
                let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, preset.constraint.isValid else { return nil }
                var copy = preset
                copy.name = name
                return copy
            }
            .prefix(maxCustomPresetCount)

        return visibleBuiltIns + custom
    }

    static func makeDefaultCustomPreset(name: String) -> SizePreset {
        SizePreset(
            name: name,
            constraint: .fixedSize(width: 1920, height: 1080)
        )
    }
}

/// The type of constraint applied during selection
enum SizeConstraint: Codable, Equatable {
    case fixedSize(width: Int, height: Int)
    case aspectRatio(width: Int, height: Int)

    var isValid: Bool {
        switch self {
        case .fixedSize(let width, let height),
             .aspectRatio(let width, let height):
            return width > 0 && height > 0
        }
    }

    /// Display name for the constraint type
    var displayName: String {
        switch self {
        case .fixedSize(let w, let h):
            return "\(w)×\(h)"
        case .aspectRatio(let w, let h):
            return "\(w):\(h)"
        }
    }
}
