#if os(iOS)
import SwiftUI
import UIKit
import PencilKit

/// Holds the PencilKit canvas so SwiftUI buttons can undo, clear and flatten.
@available(iOS 15.0, *)
final class LerixCanvasController: ObservableObject {
    weak var canvas: PKCanvasView?

    func undo() { canvas?.undoManager?.undo() }

    func clear() { canvas?.drawing = PKDrawing() }

    /// The screenshot with the drawing burned in, at the screenshot's size.
    func flatten(_ image: UIImage) -> UIImage {
        guard let canvas = canvas, canvas.bounds.width > 0, !canvas.drawing.strokes.isEmpty else { return image }
        let bounds = canvas.bounds
        let scale = image.scale * image.size.width / bounds.width
        var overlay = UIImage()
        // Render with light traits so the chosen ink colours are kept as-is.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            overlay = canvas.drawing.image(from: bounds, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            overlay.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

@available(iOS 15.0, *)
private struct LerixCanvasView: UIViewRepresentable {
    let controller: LerixCanvasController
    let color: UIColor

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: color, width: 6)
        controller.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = PKInkingTool(.pen, color: color, width: 6)
    }
}

/// Draw-on-screenshot step: PencilKit over the image, four pen colours,
/// undo and clear.
@available(iOS 15.0, *)
struct LerixAnnotationEditor: View {
    let image: UIImage
    let onDone: (UIImage) -> Void

    @StateObject private var controller = LerixCanvasController()
    @State private var colorIndex = 0

    private static let colors: [UIColor] = [.systemRed, .systemYellow, .systemBlue, .black]

    var body: some View {
        let ui = LerixUI.shared
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let fitted = Self.fit(image.size, in: geometry.size)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                    LerixCanvasView(controller: controller, color: Self.colors[colorIndex])
                        .frame(width: fitted.width, height: fitted.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .frame(width: geometry.size.width, height: geometry.size.height)
                // The screenshot isn't mirrored for right-to-left layouts.
                .environment(\.layoutDirection, .leftToRight)
            }
            HStack(spacing: 14) {
                ForEach(Self.colors.indices, id: \.self) { index in
                    Button {
                        colorIndex = index
                    } label: {
                        Circle()
                            .fill(Color(uiColor: Self.colors[index]))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.primary, lineWidth: colorIndex == index ? 2.5 : 0).padding(-4))
                    }
                    .accessibilityLabel(Text("\(index + 1)"))
                }
                Spacer()
                Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel(Text(ui.string("feedback.annotate.undo")))
                Button(ui.string("feedback.annotate.clear")) { controller.clear() }
                Button(ui.string("common.done")) { onDone(controller.flatten(image)) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 4)
        }
    }

    static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
#endif
