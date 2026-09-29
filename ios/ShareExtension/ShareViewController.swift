import SwiftUI
import UIKit

/// The share extension's screen. iOS starts the extension apart from Flux
/// and gives it little memory, so it keeps no link: it queues the items in
/// the App Group, and Flux sends them when it connects.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let composer = ShareComposer(providers: items.flatMap { $0.attachments ?? [] })
        composer.finish = { [weak self] sent in
            if sent {
                self?.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
        let host = UIHostingController(rootView: ShareView(composer: composer))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        composer.load()
    }
}
