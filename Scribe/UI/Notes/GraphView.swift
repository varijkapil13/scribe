// Scribe/UI/Notes/GraphView.swift
import SwiftUI

struct GraphView: View {
    @StateObject private var vm = GraphViewModel()
    @State private var panOffset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    var onNavigate: (String) -> Void

    var body: some View {
        Group {
            if vm.nodes.isEmpty {
                EmptyStateView(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: "No connections yet",
                    message: "Link two notes to see your graph. Add a [[wiki link]] from one note to another and they'll appear here, connected."
                )
            } else {
                canvas
            }
        }
        .navigationTitle("Graph")
        .toolbar {
            ToolbarItem {
                Button("Reset") {
                    panOffset = .zero; dragStart = .zero; zoomScale = 1; baseZoom = 1
                    Task { try? await vm.loadInBackground() }
                }
            }
        }
        .task { try? await vm.loadInBackground() }
    }

    private var canvas: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: vm.isSettled)) { timeline in
                Canvas { ctx, size in
                    let transform = CGAffineTransform(
                        translationX: size.width / 2 + panOffset.width,
                        y: size.height / 2 + panOffset.height
                    ).scaledBy(x: zoomScale, y: zoomScale)

                    // Draw edges
                    let positions = Dictionary(vm.nodes.map { ($0.id, $0.position) },
                                               uniquingKeysWith: { first, _ in first })
                    for edge in vm.edges {
                        guard let src = positions[edge.sourceId],
                              let dst = positions[edge.targetId] else { continue }
                        var path = Path()
                        path.move(to: src.applying(transform))
                        path.addLine(to: dst.applying(transform))
                        ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                    }

                    // Draw nodes + labels
                    for node in vm.nodes {
                        let pt = node.position.applying(transform)
                        let r: CGFloat = 8
                        let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                        let c = node.type.color
                        ctx.fill(Circle().path(in: rect),
                                 with: .color(red: c.r, green: c.g, blue: c.b))
                        ctx.draw(
                            Text(node.label).font(.system(size: 9)).foregroundStyle(.secondary),
                            at: CGPoint(x: pt.x, y: pt.y + r + 2),
                            anchor: .top
                        )
                    }
                }
                .onChange(of: timeline.date) { _, _ in vm.tick() }
            }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        panOffset = CGSize(
                            width: dragStart.width + v.translation.width,
                            height: dragStart.height + v.translation.height
                        )
                    }
                    .onEnded { _ in dragStart = panOffset }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { v in zoomScale = max(0.25, min(4, baseZoom * v)) }
                    .onEnded { v in baseZoom = max(0.25, min(4, baseZoom * v)) }
            )
            .onTapGesture { location in
                let size = geo.size
                let transform = CGAffineTransform(
                    translationX: size.width / 2 + panOffset.width,
                    y: size.height / 2 + panOffset.height
                ).scaledBy(x: zoomScale, y: zoomScale).inverted()
                let localPt = location.applying(transform)
                if let node = vm.nodes.min(by: {
                    dist($0.position, localPt) < dist($1.position, localPt)
                }), dist(node.position, localPt) < 20 / zoomScale {
                    onNavigate(node.id)
                }
            }
        }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x; let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
