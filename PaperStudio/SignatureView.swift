import SwiftUI

struct SignatureView: View {
    var onApply: ([[CGPoint]], CGSize) -> Void
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Signez avec votre doigt ou l’Apple Pencil, puis touchez la page pour placer votre signature.")
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                Canvas { context, _ in
                    for points in strokes + [current] where points.count > 1 {
                        var path = Path(); path.addLines(points)
                        context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                }
                .background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.gray.opacity(0.3)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        current.append(CGPoint(x: min(max(0, value.location.x), geometry.size.width), y: min(max(0, value.location.y), geometry.size.height)))
                    }
                    .onEnded { _ in
                        if current.count > 1 { strokes.append(current) }
                        current = []; canvasSize = geometry.size
                    })
                .accessibilityLabel("Zone de signature manuscrite")
            }.frame(height: 250)
            HStack {
                Button("Effacer", role: .destructive) { strokes = []; current = [] }
                Spacer()
                Button("Utiliser cette signature") { onApply(strokes, canvasSize) }
                    .buttonStyle(.borderedProminent).disabled(strokes.isEmpty)
            }
            Text("Signature graphique uniquement ; aucune certification cryptographique.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }.padding(24)
    }
}
