import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FlightLiveWidgetBundle: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
        NextFlightWidget()
    }
}

struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            FlightLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.flightCard)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.tapURL(for: context.state))
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            let presentation = FlightPresentation(attributes: attributes, state: state)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(attributes: attributes, presentation: presentation)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: state, presentation: presentation)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(attributes: attributes, state: state, presentation: presentation, isStale: context.isStale)
                }
            } compactLeading: {
                CompactLeading(state: state, presentation: presentation)
            } compactTrailing: {
                CompactTrailing(state: state, presentation: presentation)
            } minimal: {
                if state.phase.isAirborne {
                    ProgressRing(progress: state.planeProgress, tint: presentation.tone.color, interval: state.flightInterval)
                } else if !state.phase.hasDeparted, let chip = presentation.chip {
                    Text(chip.value)
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(Color.flightYellow)
                } else {
                    Image(systemName: state.phase.symbol)
                        .foregroundStyle(presentation.tone.color)
                }
            }
            .keylineTint(presentation.tone.color)
            .widgetURL(attributes.tapURL(for: state))
        }
    }
}

private struct ExpandedLeading: View {
    var attributes: FlightActivityAttributes
    var presentation: FlightPresentation

    var body: some View {
        HStack(spacing: 8) {
            AirlineBadge(code: attributes.airlineCode, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(attributes.flightNumber)
                    .font(.system(size: 15, weight: .bold))
                Text(attributes.destination.map { "to \($0.city)" } ?? presentation.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 4)
    }
}

/// The seat, or the status in words when there is no seat.
private struct ExpandedTrailing: View {
    var state: FlightActivityAttributes.ContentState
    var presentation: FlightPresentation

    var body: some View {
        Group {
            if let seat = state.seat {
                SeatTag(seat: seat)
            } else {
                Text(presentation.statusText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, 4)
    }
}

private struct ExpandedBottom: View {
    var attributes: FlightActivityAttributes
    var state: FlightActivityAttributes.ContentState
    var presentation: FlightPresentation
    var isStale: Bool

    /// "UNTIL GATE ARRIVAL". The island has no room for the context line, so an estimated position is said here.
    private var caption: String {
        let text = presentation.untilCaption.uppercased()
        return state.positionIsEstimated == true && state.phase.isAirborne ? "\(text) · POSITION ESTIMATED" : text
    }

    var body: some View {
        VStack(spacing: 6) {
            if let origin = attributes.origin, let destination = attributes.destination {
                LiveRouteRow(
                    origin: origin, destination: destination, state: state,
                    tint: presentation.tone.color, isStale: isStale
                )
            } else {
                let units = state.units ?? .aviation
                HStack {
                    MiniStat(label: "SPEED", value: units.speed(state.groundSpeedKnots))
                    Spacer()
                    MiniStat(label: "CLIMB", value: state.verticalRateFPM.map { "\($0) fpm" } ?? "—", alignment: .trailing)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    CountdownValue(presentation: presentation, size: 22)
                        .foregroundStyle(presentation.tone.color)
                    Text(caption)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                if let chip = presentation.chip {
                    GateChip(chip: chip, compact: true, showsIcon: true)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

/// A status dot and the countdown, colored by delay. Once there is nothing to count down to, the status in words.
private struct CompactLeading: View {
    var state: FlightActivityAttributes.ContentState
    var presentation: FlightPresentation

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(presentation.tone.color)
                .frame(width: 8, height: 8)
            if let target = presentation.countdownTarget, target > .now {
                // A timer text grows to fill whatever space it's offered, which pushes the
                // island wide; a fixed width sized to "1:25:00" or "25:00" keeps it compact.
                let remaining = target.timeIntervalSinceNow
                Text(timerInterval: Date.now...target, countsDown: true)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(presentation.tone.color)
                    .frame(width: remaining >= 36_000 ? 62 : remaining >= 3_600 ? 54 : 38, alignment: .leading)
            } else {
                Text(presentation.statusText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 62, alignment: .leading)
            }
        }
    }
}

/// The gate, belt or terminal. With nothing to show, a bar that fills by itself in the air (like Flighty), else the phase.
private struct CompactTrailing: View {
    var state: FlightActivityAttributes.ContentState
    var presentation: FlightPresentation

    var body: some View {
        if let chip = presentation.chip {
            GateChip(chip: chip, compact: true, showsIcon: true)
        } else if let interval = state.flightInterval {
            HStack(spacing: 5) {
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
                TimedProgressBar(interval: interval, tint: presentation.tone.color)
                    .frame(width: 34)
            }
        } else {
            Image(systemName: state.phase.symbol)
                .foregroundStyle(presentation.tone.color)
        }
    }
}

// Every phase, so none of them is only ever seen on a real flight.

#Preview("Lock Screen", as: .content, using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.scheduled
    FlightActivityAttributes.ContentState.delayed
    FlightActivityAttributes.ContentState.boarding
    FlightActivityAttributes.ContentState.taxiingOut
    FlightActivityAttributes.ContentState.cruising
    FlightActivityAttributes.ContentState.descending
    FlightActivityAttributes.ContentState.landed
    FlightActivityAttributes.ContentState.cancelled
    FlightActivityAttributes.ContentState.diverted
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.scheduled
    FlightActivityAttributes.ContentState.delayed
    FlightActivityAttributes.ContentState.boarding
    FlightActivityAttributes.ContentState.taxiingOut
    FlightActivityAttributes.ContentState.cruising
    FlightActivityAttributes.ContentState.descending
    FlightActivityAttributes.ContentState.landed
    FlightActivityAttributes.ContentState.cancelled
    FlightActivityAttributes.ContentState.diverted
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.scheduled
    FlightActivityAttributes.ContentState.delayed
    FlightActivityAttributes.ContentState.boarding
    FlightActivityAttributes.ContentState.taxiingOut
    FlightActivityAttributes.ContentState.cruising
    FlightActivityAttributes.ContentState.descending
    FlightActivityAttributes.ContentState.landed
    FlightActivityAttributes.ContentState.cancelled
    FlightActivityAttributes.ContentState.diverted
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.scheduled
    FlightActivityAttributes.ContentState.delayed
    FlightActivityAttributes.ContentState.boarding
    FlightActivityAttributes.ContentState.taxiingOut
    FlightActivityAttributes.ContentState.cruising
    FlightActivityAttributes.ContentState.descending
    FlightActivityAttributes.ContentState.landed
    FlightActivityAttributes.ContentState.cancelled
    FlightActivityAttributes.ContentState.diverted
}

#Preview("Private plane", as: .content, using: FlightActivityAttributes.noRoute) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.generalAviation
}
