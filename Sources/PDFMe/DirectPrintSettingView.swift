import SwiftUI

struct DirectPrintSettingView: View {
    @ObservedObject var model: PrintModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Direct PDF printing", isOn: $model.directPrinting)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                .disabled(model.busy)
            Text(model.directPrinting ? "Send PDF directly over IPP. Turn off to use macOS printing." : "Use macOS printing. Enable for network printers that accept PDF.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
}
