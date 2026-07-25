import Foundation

actor SidecarFileOperationService {
    private let fileManager = FileManager.default

    func createFile(named name: String, in directory: URL) throws -> URL {
        let destination = try destination(named: name, in: directory)
        guard fileManager.createFile(atPath: destination.path, contents: Data()) else {
            throw SidecarFileOperationError.cannotCreate(destination.lastPathComponent)
        }
        return destination
    }

    func createDirectory(named name: String, in directory: URL) throws -> URL {
        let destination = try destination(named: name, in: directory)
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        return destination
    }

    func rename(_ url: URL, to name: String) throws -> URL {
        let destination = try destination(
            named: name,
            in: url.deletingLastPathComponent(),
            allowingExistingItem: url
        )
        guard destination.path != url.path else { return url }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    private func destination(
        named rawName: String,
        in directory: URL,
        allowingExistingItem: URL? = nil
    ) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw SidecarFileOperationError.invalidName
        }

        let destination = directory
            .appending(path: name)
            .standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path)
                || allowingExistingItem.map({ sameFile($0, destination) }) == true else {
            throw SidecarFileOperationError.alreadyExists(name)
        }
        return destination
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsAttributes = try? fileManager.attributesOfItem(atPath: lhs.path),
              let rhsAttributes = try? fileManager.attributesOfItem(atPath: rhs.path),
              let lhsDevice = lhsAttributes[.systemNumber] as? NSNumber,
              let rhsDevice = rhsAttributes[.systemNumber] as? NSNumber,
              let lhsNode = lhsAttributes[.systemFileNumber] as? NSNumber,
              let rhsNode = rhsAttributes[.systemFileNumber] as? NSNumber else {
            return false
        }
        return lhsDevice == rhsDevice && lhsNode == rhsNode
    }
}

private enum SidecarFileOperationError: LocalizedError {
    case invalidName
    case alreadyExists(String)
    case cannotCreate(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Enter a valid file or folder name."
        case .alreadyExists(let name):
            "“\(name)” already exists."
        case .cannotCreate(let name):
            "Unable to create “\(name)”."
        }
    }
}
