import Foundation

extension Optional where Wrapped == String {
    /// Returns the wrapped string when it is non-nil and not empty; otherwise `nil`.
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
