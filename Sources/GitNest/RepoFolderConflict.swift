import Foundation

/// Describes why a local folder can't be safely used as the clone target for a
/// remote repository (e.g. it already contains a different Git repo).
struct RepoFolderConflict: Sendable, Equatable {
    let path: String
    let origin: String?

    var message: String {
        if let origin, !origin.isEmpty {
            return """
            Target folder already contains a different Git repo:
            \(path)

            origin: \(origin)

            Move or rename that folder before cloning this repository.
            """
        }
        return """
        Target path already exists, but it is not this GitHub repository:
        \(path)

        Move or rename that folder before cloning this repository.
        """
    }

    var shortHelp: String {
        if let origin, !origin.isEmpty {
            return "Folder occupied by a different repo: \(origin)"
        }
        return "Folder occupied by something that is not this repo"
    }
}

/// Whether the local path for a repo is free, already correctly cloned, or
/// occupied by something else.
enum LocalRepoFolderState: Sendable, Equatable {
    case absent
    case cloned
    case occupied(RepoFolderConflict)
}
