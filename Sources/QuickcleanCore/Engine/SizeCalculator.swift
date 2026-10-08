import Darwin
import Foundation

/// Allocated disk usage. Never follows symlinks; hard-linked files count once per calculator.
public final class SizeCalculator: Sendable {
    private struct Inode: Hashable { let device: dev_t; let inode: ino_t }
    private let seen = Locked(Set<Inode>())

    public init() {}

    public func size(of paths: [URL]) async -> Int64 {
        var total: Int64 = 0
        for url in paths { total += size(of: url) }
        return total
    }

    private func size(of url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) == S_IFLNK { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return allocated(st) }

        var total = allocated(st)
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return total }
        while let rel = walker.nextObject() as? String {
            var child = stat()
            guard lstat(url.path + "/" + rel, &child) == 0 else { continue }
            total += allocated(child)
        }
        return total
    }

    private func allocated(_ st: stat) -> Int64 {
        if (st.st_mode & S_IFMT) == S_IFLNK { return 0 }
        if st.st_nlink > 1, (st.st_mode & S_IFMT) == S_IFREG {
            let key = Inode(device: st.st_dev, inode: st.st_ino)
            var isNew = false
            seen.mutate { isNew = $0.insert(key).inserted }
            if !isNew { return 0 }
        }
        return Int64(st.st_blocks) * 512
    }
}
