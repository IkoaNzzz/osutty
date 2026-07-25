import Foundation

struct SidecarCommandMetadata: Identifiable {
    let id: UInt64
    let workingDirectory: String?
    let finishedAt: Date
    let exitCode: Int?
    let duration: TimeInterval
}

/// A passive, bounded record of command-finished events.
///
/// Keys are weak SurfaceView references, so closing a terminal releases its
/// history. Recording is event-driven and does not create timers or perform
/// terminal reads while the Sidecar is hidden.
@MainActor
final class SidecarCommandMetadataStore {
    static let shared = SidecarCommandMetadataStore()

    private final class Box: NSObject {
        var records: [SidecarCommandMetadata] = []
    }

    private let boxes = NSMapTable<Ghostty.SurfaceView, Box>.weakToStrongObjects()
    private var nextID: UInt64 = 1

    func record(
        surfaceView: Ghostty.SurfaceView,
        exitCode: Int16,
        durationNanoseconds: UInt64
    ) {
        let box = boxes.object(forKey: surfaceView) ?? {
            let value = Box()
            boxes.setObject(value, forKey: surfaceView)
            return value
        }()

        box.records.append(.init(
            id: nextID,
            workingDirectory: surfaceView.pwd,
            finishedAt: Date(),
            exitCode: exitCode < 0 ? nil : Int(exitCode),
            duration: TimeInterval(durationNanoseconds) / 1_000_000_000
        ))
        nextID &+= 1

        if box.records.count > 500 {
            box.records.removeFirst(box.records.count - 500)
        }
    }

    func records(for surfaceView: Ghostty.SurfaceView) -> [SidecarCommandMetadata] {
        boxes.object(forKey: surfaceView)?.records ?? []
    }
}
