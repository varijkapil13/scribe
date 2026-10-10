import SwiftUI

/// "Upcoming" section of the menu-bar menu: the next three calendar events
/// today. Choosing one starts a recording whose note is named after it.
/// Renders nothing while calendar integration is off (no events).
struct UpcomingEventsMenuSection: View {
    let events: [CalendarEventInfo]
    let onSelect: (CalendarEventInfo) -> Void

    var body: some View {
        let today = CalendarEventMatcher.upcomingToday(events, now: Date(), limit: 3)
        if !today.isEmpty {
            Divider()
            Section("Upcoming") {
                ForEach(today, id: \.self) { event in
                    Button("\(event.start.formatted(date: .omitted, time: .shortened))  \(event.displayTitle)") {
                        onSelect(event)
                    }
                    .help("Record \(event.displayTitle)")
                }
            }
        }
    }
}
