import SwiftUI

/// A prominent tab remains a native tab-bar item, but Compose must not select its empty content.
@available(iOS 27, *)
struct ComposeTabAction: UIViewControllerRepresentable {
    var compose: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.compose = compose
        controller.install()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.detach() }

    final class Controller: UIViewController, UITabBarControllerDelegate {
        var compose: () -> Void = {}
        private weak var tabs: UITabBarController?
        private weak var previous: (any UITabBarControllerDelegate)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); install() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); install() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); install() }

        func install() {
            func find(in controller: UIViewController) -> UITabBarController? {
                (controller as? UITabBarController) ?? controller.children.lazy.compactMap { find(in: $0) }.first
            }
            var ancestor = parent
            while let current = ancestor {
                if let owner = find(in: current) {
                    if tabs !== owner { detach(); tabs = owner }
                    if owner.delegate !== self { previous = owner.delegate; owner.delegate = self }
                    return
                }
                ancestor = current.parent
            }
        }
        func detach() {
            if let tabs, tabs.delegate === self { tabs.delegate = previous }
            tabs = nil
            previous = nil
        }
        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab.identifier == tabBarController.prominentTabIdentifier { compose(); return false }
            return previous?.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
        }
        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if let tab = tabBarController.tabs.first(where: { $0.identifier == tabBarController.prominentTabIdentifier }),
               tab.viewController === viewController { compose(); return false }
            return previous?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previous?.responds(to: selector) == true { return previous }
            return super.forwardingTarget(for: selector)
        }
    }
}
