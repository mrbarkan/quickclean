import Foundation

public enum FullDiskAccess {
    /// The TCC database can only be opened by processes with Full Disk Access.
    public static func isGranted(home: URL) -> Bool {
        let url = home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }
}
