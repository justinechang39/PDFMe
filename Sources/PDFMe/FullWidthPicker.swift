import AppKit
import SwiftUI

/// A native pop-up whose control, not just its surrounding frame, fills the row.
struct FullWidthPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.font = .systemFont(ofSize: 12)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map { $0.1 }
        if button.itemTitles != titles {
            button.removeAllItems()
            // Add separately so distinct choices may have the same display name.
            for title in titles { button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        }
        button.selectItem(at: options.firstIndex { $0.0 == selection } ?? -1)
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 26)
    }

    final class Coordinator: NSObject {
        var parent: FullWidthPicker
        init(_ parent: FullWidthPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].0
        }
    }
}
