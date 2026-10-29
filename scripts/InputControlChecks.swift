import AppKit
import SwiftUI
import PDFMeCore

/// Exercises the actual SwiftUI/AppKit editor in a hidden window; never opens PDFs or prints.
@main struct InputControlChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let model = PrintModel()
        let input = PrintInput(url: URL(fileURLWithPath: "/tmp/Physics exam paper.pdf"), pages: 40, pageSelection: .custom("1-15, 21-end"))
        model.inputs = [input]
        let root = VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Physics exam paper.pdf").font(.system(size:12, weight:.medium))
                    Text("40 pages").font(.system(size:10)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .leading, spacing:4) {
                    Text("Copies").font(.system(size:9)).foregroundStyle(.secondary)
                    CopiesField(model:model,id:input.id)
                }
                Image(systemName:"ellipsis")
                Image(systemName:"line.3.horizontal")
            }
            PageSelectionControls(model:model,id:input.id)
        }.padding(10).frame(width:258).background(.white).preferredColorScheme(.light)
        let view = NSHostingView(rootView:root)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:258,height:130),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=view
        view.frame=NSRect(x:0,y:0,width:258,height:130)
        RunLoop.current.run(until:Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        func fields(_ v: NSView) -> [NSTextField] {
            (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap { fields($0) }
        }
        guard let copies = fields(view).first(where: { $0.isEditable && $0.stringValue == "1" }) else { fatalError("Copies text field not found") }
        window.makeFirstResponder(copies)
        copies.selectText(nil)
        guard let editor = copies.currentEditor() as? NSTextView else { fatalError("No actual field editor") }
        editor.setSelectedRange(NSRange(location:0,length:1))
        editor.deleteBackward(nil)
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        precondition(editor.string.isEmpty, "Backspace must leave the actual field empty")
        precondition(model.copiesText(for:input.id).isEmpty, "Empty draft must reach the model")
        precondition(model.inputProblem != nil, "Empty visible copies must block print")
        editor.insertText("4",replacementRange:editor.selectedRange())
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        precondition(editor.string == "4", "Typed 4 must stay 4")
        precondition(model.inputs[0].copies == 4 && model.inputProblem == nil, "4 copies must apply immediately")
        window.makeFirstResponder(nil)
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        precondition(copies.stringValue == "4", "4 must remain after blur")
        print("PASS: Actual SwiftUI/AppKit field editor supports select, backspace to empty, type 4, and blur; invalid draft blocks printing.")
        window.makeFirstResponder(copies)
        copies.selectText(nil)
        guard let again = copies.currentEditor() as? NSTextView else { fatalError("Missing field editor on refocus") }
        again.setSelectedRange(NSRange(location:0,length:again.string.utf16.count))
        again.deleteBackward(nil)
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        precondition(again.string.isEmpty && model.inputProblem != nil, "Clearing again must remain editable")
        window.makeFirstResponder(nil)
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        precondition(copies.stringValue == "4" && model.inputProblem == nil, "Blurring an empty field must visibly restore 4")
        print("PASS: Leaving an empty actual text field restores the last valid count on screen.")
        model.cleanup()
    }
}
