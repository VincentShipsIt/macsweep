import Foundation

// MARK: - Space Lens (disk tree)

public struct HeadlessDiskNode: Codable, Sendable {
    public let name: String
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    /// Coarse type classifier: "directory" for folders, otherwise the lowercased
    /// file extension (e.g. "log", "zip") or "file" when there is none. Lets agents
    /// reason about what a large leaf node is without re-stat'ing the path.
    public let fileType: String
    public let lastModified: Date?
    /// Number of direct children retained after any `--min-size` pruning (the
    /// `children` array is the full, depth-bounded, post-filter set).
    public let childCount: Int
    public let children: [HeadlessDiskNode]

    public init(
        name: String,
        path: String,
        size: Int64,
        isDirectory: Bool,
        fileType: String,
        lastModified: Date?,
        childCount: Int,
        children: [HeadlessDiskNode]
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.fileType = fileType
        self.lastModified = lastModified
        self.childCount = childCount
        self.children = children
    }
}

public struct HeadlessDiskTree: Codable, Sendable {
    public let rootPath: String
    public let depth: Int
    public let totalBytes: Int64
    public let root: HeadlessDiskNode

    public init(rootPath: String, depth: Int, totalBytes: Int64, root: HeadlessDiskNode) {
        self.rootPath = rootPath
        self.depth = depth
        self.totalBytes = totalBytes
        self.root = root
    }
}

