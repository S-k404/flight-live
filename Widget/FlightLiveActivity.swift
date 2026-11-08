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
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(presentation.countdownLabel.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                        CountdownValue(presentation: presentation, size: 20, alignment: .trailing)
                            .foregroundStyle(presentation.tone.color)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(attributes: attributes, state: state, presentation: presentation, isStale: context.isStale)
                }
            } compactLeading: {
                CompactLeading(attributes: attributes, state: state, presentation: presentation)
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

private struct ExpandedBottom: View {
    var attributes: FlightActivityAttributes
    var state: FlightActivityAttributes.ContentState
    var presentation: FlightPresentation
    var isStale: Bool

    var body: some View {
        VStack(spacing: 9) {
            if let origin = attributes.origin, let destination = attributes.destination {
                let muted = state.phase == .cancelled
                HStack(spacing: 10) {
                    EndpointLabel(airport: origin, movement: state.departure, alignment: .leading, muted: muted)
                    RouteProgressBar(
                        progress: state.planeProgress,
                        tint: presentation.tone.color,
                        interval: state.flightInterval,
                        showsPlane: !isStale
                    )
                    EndpointLabel(airport: destination, movement: state.arrival, alignment: .trailing, muted: muted)
                }
            } else {
                let units = state.units ?? .aviation
                HStack {
                    MiniStat(label: "SPEED", value: units.speed(state.groundSpeedKnots))
                    Spacer()
                    MiniStat(label: "CLIMB", value: state.verticalRateFPM.map { "\($0) fpm" } ?? "—", alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                Text(presentation.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .id(presentation.detail)
                    .transition(.push(from: .bottom))
                Spacer(minLength: 4)
                if let chip = presentation.chip {
                    HStack(spacing: 4) {
                        Text(chip.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                        GateChip(chip: chip, compact: true)
                    }
                } else {
                    Text(presentation.statusText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(presentation.tone.color)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

/// Gate before departure; in the air, a small bar that fills by itself (like Flighty); otherwise the destination.
private struct CompactLeading: View {
    var attributes: FlightActivityAttributes
    var state: FlightActivityAttributes.ContentState
    var presentation: FlightPresentation

    var body: some View {
        if !state.phase.hasDeparted, let chip = presentation.chip {
            GateChip(chip: chip, compact: true)
        } else if let interval = state.flightInterval {
            HStack(spacing: 5) {
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
                TimedProgressBar(interval: interval, tint: presentation.tone.color)
                    .frame(width: 34)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: state.phase.isAirborne ? "airplane" : state.phase.symbol)
                    .foregroundStyle(presentation.tone.color)
                Text(attributes.destination?.code ?? attributes.flightNumber)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
        }
    }
}

/// Countdown to departure or arrival, colored by delay.
private struct CompactTrailing: View {
    var state: FlightActivityAttributes.ContentState
    var presentation: FlightPresentation

    var body: some View {
        if let target = presentation.countdownTarget, target > .now {
            // A timer text grows to fill whatever space it's offered, which pushes the
            // island wide; a fixed width sized to "1:25:00" or "25:00" keeps it compact.
            let remaining = target.timeIntervalSinceNow
            Text(timerInterval: Date.now...target, countsDown: true)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(presentation.tone.color)
                .frame(width: remaining >= 36_000 ? 70 : remaining >= 3_600 ? 62 : 46, alignment: .trailing)
        } else if state.phase.isFinal {
            Image(systemName: state.phase.symbol)
                .foregroundStyle(presentation.tone.color)
        } else {
            Text(presentation.statusText)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(presentation.tone.color)
                .lineLimit(1)
                .frame(maxWidth: 70)
        }
    }
}

#Preview("Lock Screen", as: .content, using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.scheduled
    FlightActivityAttributes.ContentState.boarding
    FlightActivityAttributes.ContentState.cruising
    FlightActivityAttributes.ContentState.descending
    FlightActivityAttributes.ContentState.landed
    FlightActivityAttributes.ContentState.cancelled
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.scheduled
    FlightActivityAttributes.ContentState.cruising
    FlightActivityAttributes.ContentState.landed
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.scheduled
    FlightActivityAttributes.ContentState.cruising
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: FlightActivityAttributes.demo) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.cruising
}

#Preview("Private plane", as: .content, using: FlightActivityAttributes.noRoute) {
    FlightLiveActivity()
} contentStates: {
    FlightActivityAttributes.ContentState.generalAviation
}
