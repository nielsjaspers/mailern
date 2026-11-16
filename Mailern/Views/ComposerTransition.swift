import SwiftUI

struct ComposerTransition: ViewModifier {
    let source: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        content.navigationTransition(.zoom(sourceID: source, in: namespace))
    }
}

struct ComposerSource: ViewModifier {
    let source: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        content.matchedTransitionSource(id: source, in: namespace)
    }
}
