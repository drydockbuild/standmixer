import Darwin
import Foundation

/// Checks a CLI's native configuration/authentication root without following links or
/// listing directory contents. A missing descendant is allowed only after its existing
/// ancestors have passed the same no-follow directory checks.
enum AgentImportRootSafety {
    static func isSafe(_ url: URL) -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return false }
        let path = url.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Do not normalize away a component that might itself be a symlink.
        guard !components.contains("..") else { return false }
        components.removeAll { $0 == "." }

        // These are fixed operating-system aliases. Rewriting their spelling requires
        // no filesystem lookup and does not authorize any user-created symlink.
        if let first = components.first, ["var", "tmp", "etc"].contains(first.lowercased()) {
            components[0] = first.lowercased()
            components.insert("private", at: 0)
        }
        guard !components.contains(where: isProtectedComponent) else { return false }

        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        for component in components {
            let child = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else {
                let failure = errno
                return failure == ENOENT
            }
            Darwin.close(descriptor)
            descriptor = child
        }
        return true
    }

    private static func isProtectedComponent(_ component: String) -> Bool {
        let folded = component.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let normalized = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined().lowercased()
        let exact: Set<String> = ["music", "movies", "pictures", "photos", "downloads", "desktop", "documents",
                                  "library", "cloudstorage", "mobiledocuments"]
        return exact.contains(normalized) || ["icloud", "googledrive", "dropbox", "onedrive"].contains(where: normalized.hasPrefix)
    }
}
