import Foundation
import GhosttyKit

struct SidecarCoreCommand: Sendable {
    let row: UInt32
    let hasFollowingPrompt: Bool
    let command: String
}

enum SidecarOutlineSnapshotUpdate: Sendable {
    case unchanged
    case changed(generation: UInt64, commands: [SidecarCoreCommand])
    case failed
}

/// Reads the bounded semantic-command snapshot through the thread-safe core
/// API. The call holds Ghostty's renderer mutex, so it runs on this actor
/// instead of the main actor.
actor SidecarOutlineService {
    func snapshot(
        surface: Ghostty.Surface,
        previousGeneration: UInt64?,
        limit: UInt32 = 500
    ) -> SidecarOutlineSnapshotUpdate {
        let rawSurface = surface.unsafeCValue
        var text = ghostty_text_s()
        var generation: UInt64 = 0
        let previousGeneration = previousGeneration ?? UInt64.max
        guard ghostty_surface_command_outline_if_changed(
            rawSurface,
            limit,
            previousGeneration,
            &generation,
            &text
        ) else {
            return .failed
        }
        guard generation != previousGeneration else { return .unchanged }
        defer { ghostty_surface_free_text(rawSurface, &text) }

        guard let pointer = text.text, text.text_len > 0 else {
            return .changed(generation: generation, commands: [])
        }
        let data = Data(bytes: pointer, count: Int(text.text_len))
        return .changed(
            generation: generation,
            commands: SidecarOutlineParser.parse(data)
        )
    }
}

enum SidecarOutlineParser {
    static func parse(_ data: Data) -> [SidecarCoreCommand] {
        var commands: [SidecarCoreCommand] = []
        var offset = 0

        while offset + 9 <= data.count {
            let row = data.littleEndianUInt32(at: offset)
            let flags = data[offset + 4]
            let length = Int(data.littleEndianUInt32(at: offset + 5))
            offset += 9

            guard offset + length <= data.count else { break }
            let bytes = data[offset..<(offset + length)]
            offset += length

            guard let command = String(bytes: bytes, encoding: .utf8) else {
                continue
            }
            commands.append(.init(
                row: row,
                hasFollowingPrompt: flags & 1 == 1,
                command: command
            ))
        }

        return commands
    }
}

private extension Data {
    func littleEndianUInt32(at index: Int) -> UInt32 {
        UInt32(self[index])
            | UInt32(self[index + 1]) << 8
            | UInt32(self[index + 2]) << 16
            | UInt32(self[index + 3]) << 24
    }
}
