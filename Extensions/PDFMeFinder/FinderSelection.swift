import Foundation

/// Keep the menu lightweight: validate selection shape here, inspect PDF contents in the app.
enum FinderSelection {
    static func accepts(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy {
            $0.isFileURL && !$0.hasDirectoryPath && $0.pathExtension.lowercased() == "pdf"
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
    }
}
