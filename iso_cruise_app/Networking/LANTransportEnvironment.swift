import SwiftUI

extension EnvironmentValues {
    /// The LAN side of the transport, for the screens that need to offer a join code.
    ///
    /// Passed through the environment rather than as a view parameter because the only views
    /// that want it (Troubleshooting, and the join sheet) sit several levels below the root,
    /// and threading an optional transport through Chat and Profile purely to reach them
    /// would couple those screens to something they don't use.
    ///
    /// Nil in previews and in demo builds, where the transport is faked.
    @Entry var lanTransport: LANTransport?
}
