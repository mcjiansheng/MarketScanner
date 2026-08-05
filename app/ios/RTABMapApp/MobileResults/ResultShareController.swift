import UIKit

/// Shares the exported result workbook through the system share sheet.
enum ResultShareController {
    static func share(
        workbookURL: URL,
        from presenter: UIViewController,
        sourceView: UIView? = nil
    ) {
        let activity = UIActivityViewController(
            activityItems: [workbookURL], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = sourceView ?? presenter.view
            popover.sourceRect = sourceView?.bounds ?? presenter.view.bounds
        }
        presenter.present(activity, animated: true)
    }
}
