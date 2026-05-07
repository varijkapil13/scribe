// Scribe/UI/Notes/GraphViewModel.swift
import Foundation
import CoreGraphics

struct GraphNode: Identifiable, Sendable {
    let id: String
    let label: String
    let type: NodeType
    var position: CGPoint
    var velocity: CGPoint = .zero

    enum NodeType: Equatable, Sendable {
        case note
        var color: (r: Double, g: Double, b: Double) {
            switch self {
            case .note: return (0.2, 0.5, 1.0)
            }
        }
    }
}

struct GraphEdge: Sendable {
    let sourceId: String
    let targetId: String
}

@MainActor
final class GraphViewModel: ObservableObject {
    @Published private(set) var nodes: [GraphNode] = []
    @Published private(set) var edges: [GraphEdge] = []
    @Published private(set) var isSettled: Bool = true

    private let noteStore: NoteStore
    private var isSimulating = false

    init(noteStore: NoteStore = .shared) {
        self.noteStore = noteStore
    }

    func load() throws {
        let notes = try noteStore.fetchAllNotes()
        guard !notes.isEmpty else {
            nodes = []; edges = []; isSettled = true; return
        }

        nodes = notes.map { note in
            GraphNode(
                id: note.id,
                label: note.title.isEmpty ? "(Untitled)" : String(note.title.prefix(20)),
                type: .note,
                position: CGPoint(
                    x: Double.random(in: 50...550),
                    y: Double.random(in: 50...550)
                )
            )
        }

        edges = try noteStore.fetchAllLinks().map { GraphEdge(sourceId: $0.sourceNoteId,
                                                              targetId: $0.targetNoteId) }
        isSettled = nodes.count <= 1
    }

    func tick() {
        guard !isSettled, nodes.count > 1, !isSimulating else {
            if nodes.count <= 1 { isSettled = true }
            return
        }
        isSimulating = true
        let snapshot = nodes
        let edgeSnapshot = edges
        Task.detached(priority: .userInitiated) { [weak self] in
            let (updated, settled) = Self.simulate(nodes: snapshot, edges: edgeSnapshot)
            await MainActor.run {
                self?.nodes = updated
                self?.isSettled = settled
                self?.isSimulating = false
            }
        }
    }

    // Pure function — runs off the main actor.
    private nonisolated static func simulate(nodes: [GraphNode], edges: [GraphEdge]) -> ([GraphNode], Bool) {
        let repulsionK: Double = 2000
        let springK: Double = 0.04
        let restLength: Double = 120
        let damping: Double = 0.85

        var result = nodes
        var forces = Array(repeating: CGPoint.zero, count: nodes.count)

        // H6: O(1) lookup instead of O(N) firstIndex per edge.
        let idToIndex = Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, $0) })

        for i in nodes.indices {
            for j in nodes.indices where j != i {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let distSq = max(dx * dx + dy * dy, 1)
                let dist = distSq.squareRoot()
                let force = repulsionK / distSq
                forces[i].x += force * dx / dist
                forces[i].y += force * dy / dist
            }
        }

        for edge in edges {
            guard let si = idToIndex[edge.sourceId],
                  let ti = idToIndex[edge.targetId] else { continue }
            let dx = nodes[ti].position.x - nodes[si].position.x
            let dy = nodes[ti].position.y - nodes[si].position.y
            let dist = max((dx * dx + dy * dy).squareRoot(), 1)
            let stretch = dist - restLength
            let force = springK * stretch
            forces[si].x += force * dx / dist
            forces[si].y += force * dy / dist
            forces[ti].x -= force * dx / dist
            forces[ti].y -= force * dy / dist
        }

        var maxSpeed: Double = 0
        for i in result.indices {
            result[i].velocity.x = (result[i].velocity.x + forces[i].x) * damping
            result[i].velocity.y = (result[i].velocity.y + forces[i].y) * damping
            result[i].position.x += result[i].velocity.x
            result[i].position.y += result[i].velocity.y
            let speed = (result[i].velocity.x * result[i].velocity.x
                       + result[i].velocity.y * result[i].velocity.y).squareRoot()
            maxSpeed = max(maxSpeed, speed)
        }

        return (result, maxSpeed < 0.5)
    }
}
