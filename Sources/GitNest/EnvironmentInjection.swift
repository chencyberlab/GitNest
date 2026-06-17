import SwiftUI

extension View {
    /// Inject AppModel plus every observable child manager, so any view (and any
    /// sheet/popover, which gets a fresh environment branch) can observe what it
    /// needs. Apply at the app root AND at every sheet/popover content root.
    func gitNestEnvironment(_ model: AppModel) -> some View {
        self
            .environmentObject(model)
            .environmentObject(model.accountManager)
            .environmentObject(model.repoManager)
            .environmentObject(model.repoActionCoordinator)
            .environmentObject(model.projectWorkflow)
            .environmentObject(model.setupCoordinator)
            .environmentObject(model.logStore)
            .environmentObject(model.alertStore)
    }
}
