import SwiftUI
import UIKit

#if canImport(SwiftTerm)
import SwiftTerm

struct SwiftTermTerminalViewRepresentable: UIViewRepresentable {
    let sessionID: UUID
    let outputChunks: [TerminalOutputChunk]
    let fontSize: Double
    var onInputData: (Data) -> Void
    var onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        applyAppearance(to: view, coordinator: context.coordinator)
        view.feed(text: "\u{1B}[2J\u{1B}[H")
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onInputData = onInputData
        context.coordinator.onResize = onResize
        applyAppearance(to: uiView, coordinator: context.coordinator)

        if context.coordinator.sessionID != sessionID {
            context.coordinator.sessionID = sessionID
            context.coordinator.lastRenderedSequence = -1
            uiView.feed(text: "\u{1B}[2J\u{1B}[H")
        }

        for chunk in outputChunks where chunk.sequence > context.coordinator.lastRenderedSequence {
            context.coordinator.feedRemoteData(chunk.data, into: uiView)
            context.coordinator.lastRenderedSequence = chunk.sequence
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: sessionID, onInputData: onInputData, onResize: onResize)
    }

    private func applyAppearance(to terminalView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        terminalView.backgroundColor = .black

        let clampedFontSize = min(24, max(10, fontSize))
        guard coordinator.appliedFontSize != clampedFontSize else {
            return
        }

        terminalView.font = UIFont.monospacedSystemFont(
            ofSize: clampedFontSize,
            weight: .regular
        )
        coordinator.appliedFontSize = clampedFontSize
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var sessionID: UUID
        var lastRenderedSequence = -1
        var appliedFontSize: Double?
        var onInputData: (Data) -> Void
        var onResize: (Int, Int) -> Void

        init(
            sessionID: UUID,
            onInputData: @escaping (Data) -> Void,
            onResize: @escaping (Int, Int) -> Void
        ) {
            self.sessionID = sessionID
            self.onInputData = onInputData
            self.onResize = onResize
        }

        func feedRemoteData(_ data: Data, into terminalView: SwiftTerm.TerminalView) {
            guard !data.isEmpty else { return }
            let bytes = [UInt8](data)
            terminalView.feed(byteArray: bytes[...])
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            onInputData(Data(data))
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: SwiftTerm.TerminalView) {}

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }

        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? {
            UIPasteboard.general.string?.data(using: .utf8)
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
#else
struct SwiftTermTerminalViewRepresentable: View {
    let sessionID: UUID
    let outputChunks: [TerminalOutputChunk]
    let fontSize: Double
    var onInputData: (Data) -> Void
    var onResize: (Int, Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(outputChunks) { chunk in
                    Text(String(decoding: chunk.data, as: UTF8.self))
                        .font(.system(size: fontSize, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .background(Color.black)
        .foregroundStyle(.white)
    }
}
#endif
