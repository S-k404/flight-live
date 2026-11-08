import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The boarding pass section on a flight's screen: add one from Photos or Files, see seat and
/// booking code read from its barcode, and tap it to show it full screen at the gate.
struct BoardingPassCard: View {
    var flight: TrackedFlight

    @Environment(FlightStore.self) private var store
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var working = false
    @State private var message: String?
    @State private var showingPass = false
    @State private var copied = 0

    private var image: UIImage? {
        flight.hasBoardingPass == true ? BoardingPassStore.image(for: flight.id) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BOARDING PASS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if working { ProgressView() }
                if image != nil {
                    Menu {
                        addButtons
                        Button(role: .destructive) {
                            Task { await store.removeBoardingPass(from: flight.id) }
                        } label: {
                            Label("Remove Boarding Pass", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                }
            }

            if let image {
                Button {
                    showingPass = true
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Label("Show at the gate", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                }
                .buttonStyle(.plain)
            } else {
                Text("Add a screenshot or PDF of your boarding pass. FlightLive reads the seat and booking code from its barcode, and you can open it full screen at the gate, even from the Lock Screen.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                HStack {
                    addButtons
                }
                .buttonStyle(.bordered)
            }

            if flight.seat != nil || flight.confirmationCode != nil || flight.passengerName != nil {
                HStack(spacing: 8) {
                    if let seat = flight.seat {
                        GateChip(chip: .init(label: "SEAT", value: seat))
                    }
                    if let code = flight.confirmationCode {
                        Button {
                            UIPasteboard.general.string = code
                            copied += 1
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(copied > 0 ? "COPIED" : "BOOKING · TAP TO COPY")
                                    .font(.system(size: 8, weight: .heavy))
                                    .opacity(0.6)
                                Text(code)
                                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.success, trigger: copied)
                    }
                    Spacer(minLength: 0)
                }
                if let name = flight.passengerName {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                }
            }

            if let mismatch = flight.boardingPassMismatch {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.flightAmber)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .foregroundStyle(.white)
        .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let picked = UIImage(data: data) {
                    await attach(picked)
                } else {
                    message = "Couldn't open that photo."
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image, .pdf]) { result in
            guard case .success(let url) = result else { return }
            Task {
                if let picked = BoardingPassStore.image(fromFile: url) {
                    await attach(picked)
                } else {
                    message = "Couldn't open that file."
                }
            }
        }
        .fullScreenCover(isPresented: $showingPass) {
            BoardingPassViewer(flight: flight)
        }
    }

    @ViewBuilder
    private var addButtons: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label("From Photos", systemImage: "photo")
        }
        Button {
            importingFile = true
        } label: {
            Label("From Files", systemImage: "doc")
        }
    }

    private func attach(_ picked: UIImage) async {
        working = true
        defer { working = false }
        do {
            let info = try await store.attachBoardingPass(picked, to: flight.id)
            message = info == nil
                ? "Saved. Couldn't read a barcode, so add your seat with Edit times, gate & boarding."
                : nil
        } catch {
            message = "Couldn't save the boarding pass: \(error.localizedDescription)"
        }
    }
}

/// The boarding pass full screen with the display at full brightness, for scanners at the gate.
struct BoardingPassViewer: View {
    var flight: TrackedFlight

    @Environment(\.dismiss) private var dismiss
    @State private var previousBrightness: CGFloat?

    private var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.attributes.flightNumber)
                            .font(.title2.weight(.bold))
                        if let origin = flight.attributes.origin, let destination = flight.attributes.destination {
                            Text("\(origin.code) → \(destination.code)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let gate = flight.state.departure.gate {
                        GateChip(chip: .init(label: "GATE", value: gate))
                    }
                    if let seat = flight.seat {
                        GateChip(chip: .init(label: "SEAT", value: seat))
                    }
                }
                .foregroundStyle(.black)
                .padding(.horizontal)

                if let image = BoardingPassStore.image(for: flight.id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .preferredColorScheme(.light)
        .statusBarHidden()
        .onAppear {
            guard let screen else { return }
            previousBrightness = screen.brightness
            screen.brightness = 1
        }
        .onDisappear {
            if let previousBrightness { screen?.brightness = previousBrightness }
        }
    }
}

/// Wraps a flight id for `fullScreenCover(item:)` when a Live Activity tap asks for the boarding pass.
struct BoardingPassRoute: Identifiable {
    let id: UUID
}
