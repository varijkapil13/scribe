import Foundation

// MARK: - Overlap layout

/// One block to place on a day's time grid (a calendar event or a scheduled
/// task).
struct TimeGridInterval: Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date
}

/// Where a block sits horizontally: column `column` of `columnCount` equal
/// columns, spanning `span` columns (≥ 1) when the columns to its right are
/// free for its whole duration.
struct TimeGridPlacement: Equatable, Sendable {
    let column: Int
    let columnCount: Int
    let span: Int

    /// Leading edge as a fraction of the day column's width.
    var leadingFraction: Double { Double(column) / Double(max(1, columnCount)) }
    /// Width as a fraction of the day column's width.
    var widthFraction: Double { Double(span) / Double(max(1, columnCount)) }
}

/// Fantastical / Calendar-style overlap layout: blocks that overlap in time
/// (directly or through a chain) form a cluster; each cluster is split into
/// as many columns as it needs, every block takes the first free column, and
/// then widens into free columns to its right. Pure.
enum TimeGridLayout {

    /// Blocks shorter than this are laid out as if they lasted this long, so
    /// a 5-minute task drawn at the minimum block height doesn't overlap a
    /// neighbour it was computed not to touch.
    nonisolated static let defaultMinimumDuration: TimeInterval = 15 * 60

    nonisolated static func layout(
        _ intervals: [TimeGridInterval],
        minimumDuration: TimeInterval
    ) -> [String: TimeGridPlacement] {
        struct Item {
            let id: String
            let start: Date
            let end: Date
        }
        let items = intervals.map { interval in
            Item(id: interval.id,
                 start: interval.start,
                 end: max(interval.end, interval.start.addingTimeInterval(minimumDuration)))
        }
        .sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }   // longer first
            return a.id < b.id
        }

        var result: [String: TimeGridPlacement] = [:]
        var cluster: [(item: Item, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd: Date = .distantPast

        func closeCluster() {
            guard !cluster.isEmpty else { return }
            let count = columnEnds.count
            for entry in cluster {
                var span = 1
                var next = entry.column + 1
                while next < count {
                    let blocked = cluster.contains { other in
                        other.column == next
                            && other.item.start < entry.item.end
                            && entry.item.start < other.item.end
                    }
                    if blocked { break }
                    span += 1
                    next += 1
                }
                result[entry.item.id] = TimeGridPlacement(column: entry.column, columnCount: count, span: span)
            }
            cluster.removeAll()
            columnEnds.removeAll()
            clusterEnd = .distantPast
        }

        for item in items {
            if item.start >= clusterEnd { closeCluster() }
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                columnEnds[free] = item.end
                cluster.append((item: item, column: free))
            } else {
                columnEnds.append(item.end)
                cluster.append((item: item, column: columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, item.end)
        }
        closeCluster()
        return result
    }
}

// MARK: - Vertical geometry + snapping

/// Maps minutes of the day to points on the grid and back, snapping to a
/// fixed step (15 minutes). The grid always shows a whole day, 00:00–24:00.
struct TimeGridGeometry: Equatable, Sendable {
    /// Points per hour.
    var hourHeight: Double
    /// Snap step in minutes.
    var snapMinutes: Int

    nonisolated static let minutesPerDay = 24 * 60

    nonisolated init(hourHeight: Double, snapMinutes: Int) {
        self.hourHeight = hourHeight
        self.snapMinutes = max(1, snapMinutes)
    }

    nonisolated var totalHeight: Double { hourHeight * 24 }

    nonisolated func y(forMinute minute: Double) -> Double {
        minute / 60 * hourHeight
    }

    nonisolated func minute(forY y: Double) -> Double {
        guard hourHeight > 0 else { return 0 }
        return y / hourHeight * 60
    }

    /// `minutes` rounded to the nearest snap step.
    nonisolated func snap(_ minutes: Double) -> Int {
        let step = Double(snapMinutes)
        return Int((minutes / step).rounded()) * snapMinutes
    }

    /// Start minute for a drop at `y` (snapped; a block of `duration` minutes
    /// stays inside the day).
    nonisolated func startMinute(forY y: Double, durationMinutes duration: Int) -> Int {
        clampStart(snap(minute(forY: y)), durationMinutes: duration)
    }

    /// New start after dragging a block that started at `startMinute` by
    /// `deltaY` points (snapped, kept inside the day).
    nonisolated func movedStart(startMinute: Int, durationMinutes duration: Int, deltaY: Double) -> Int {
        clampStart(snap(Double(startMinute) + minute(forY: deltaY)), durationMinutes: duration)
    }

    /// New duration after dragging a block's bottom edge by `deltaY` points:
    /// snapped, at least one step, and ending by midnight.
    nonisolated func resizedDuration(startMinute: Int, durationMinutes duration: Int, deltaY: Double) -> Int {
        let raw = snap(Double(duration) + minute(forY: deltaY))
        let maxDuration = max(snapMinutes, Self.minutesPerDay - startMinute)
        return min(max(raw, snapMinutes), maxDuration)
    }

    nonisolated func clampStart(_ start: Int, durationMinutes duration: Int) -> Int {
        let length = min(max(duration, snapMinutes), Self.minutesPerDay)
        let latest = max(0, Self.minutesPerDay - length)
        // Keep the latest start on the snap grid too.
        let latestSnapped = latest - latest % snapMinutes
        return min(max(start, 0), latestSnapped)
    }

    // MARK: Dates

    /// Minutes from the start of `day` to `date` (negative before the day,
    /// over 1440 after it). Wall-clock based, so DST days read naturally.
    nonisolated static func minuteOfDay(for date: Date, on day: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: day)
        if calendar.isDate(date, inSameDayAs: start) {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        return Int((date.timeIntervalSince(start) / 60).rounded(.down))
    }

    /// The date at `minute` of `day` (wall clock; 1440 = next midnight).
    nonisolated static func date(atMinute minute: Int, on day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        if minute >= minutesPerDay {
            return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        }
        let clamped = max(0, minute)
        return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: start)
            ?? start.addingTimeInterval(TimeInterval(clamped * 60))
    }
}
