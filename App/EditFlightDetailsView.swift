import SwiftUI

/// Enter departure and arrival times, the gate and when boarding starts, e.g. from your boarding pass.
struct EditFlightDetailsView: View {
    var flight: TrackedFlight

    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var departure: Date
    @State private var hasArrival: Bool
    @State private var arrival: Date
    @State private var gate: String
    @State private var boardingMinutes: Int
    @State private var seat: String
    @State private var confirmationCode: String
    @State private var saving = false

    private static let boardingChoices = [15, 20, 25, 30, 35, 40, 45, 50, 60]

    init(flight: TrackedFlight) {
        self.flight = flight
        let suggested = Calendar.current.date(bySetting: .minute, value: 0, of: .now.addingTimeInterval(3 * 3600)) ?? .now
        let departure = flight.state.departure.best ?? suggested
        _departure = State(initialValue: departure)
        _hasArrival = State(initialValue: flight.state.arrival.best != nil)
        _arrival = State(initialValue: flight.state.arrival.best ?? departure.addingTimeInterval(3 * 3600))
        _gate = State(initialValue: flight.state.departure.gate ?? "")
        _boardingMinutes = State(initialValue: flight.boardingMinutes ?? TrackedFlight.defaultBoardingMinutes)
        _seat = State(initialValue: flight.seat ?? "")
        _confirmationCode = State(initialValue: flight.confirmationCode ?? "")
    }

    private var canEditTimes: Bool { flight.schedule == nil }
    private var originZone: TimeZone { flight.attributes.origin?.timeZone ?? .current }
    private var destinationZone: TimeZone { flight.attributes.destination?.timeZone ?? .current }

    private var boardingTime: Date {
        (canEditTimes ? departure : flight.state.departure.best ?? departure)
            .addingTimeInterval(-TimeInterval(boardingMinutes * 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if canEditTimes {
                        DatePicker("Departs", selection: $departure)
                            .environment(\.timeZone, originZone)
                    } else if let best = flight.state.departure.best {
                        LabeledContent("Departs", value: best.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: originZone)))
                    }
                    TextField("Gate (optional)", text: $gate)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Seat (optional)", text: $seat)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Booking code (optional)", text: $confirmationCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Departure · \(flight.attributes.origin?.code ?? "")")
                } footer: {
                    if canEditTimes {
                        Text("Times are in \(flight.attributes.origin?.city ?? "local") time. Copy them from your boarding pass or booking.")
                    } else {
                        Text("Times come from the schedule and update automatically.")
                    }
                }

                if !flight.state.phase.isFinal {
                    Section {
                        Picker("Boarding starts", selection: $boardingMinutes) {
                            ForEach(Self.boardingChoices, id: \.self) { minutes in
                                Text("\(minutes) min before").tag(minutes)
                            }
                        }
                        LabeledContent("Boarding at", value: FlightPresentation.time(boardingTime, originZone))
                    } header: {
                        Text("Boarding")
                    } footer: {
                        Text("You'll get a notification when boarding starts, even if FlightLive is closed. Most airlines board 30–45 minutes before departure; your boarding pass shows the exact time.")
                    }
                }

                if canEditTimes {
                    Section("Arrival · \(flight.attributes.destination?.code ?? "")") {
                        Toggle("Arrival time", isOn: $hasArrival)
                        if hasArrival {
                            DatePicker("Arrives", selection: $arrival, in: departure...)
                                .environment(\.timeZone, destinationZone)
                        }
                    }
                }
            }
            .navigationTitle("Flight Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving)
                }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            await store.updateDetails(
                flight.id,
                departure: canEditTimes ? departure : flight.state.departure.estimated,
                arrival: canEditTimes ? (hasArrival ? arrival : nil) : flight.state.arrival.estimated,
                gate: gate,
                boardingMinutes: boardingMinutes,
                seat: seat,
                confirmationCode: confirmationCode
            )
            dismiss()
        }
    }
}
