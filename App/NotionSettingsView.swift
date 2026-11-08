import SwiftUI

/// Connects a Notion database of flights: the integration secret, which database, and importing.
struct NotionSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(FlightStore.self) private var store
    @State private var sources: [NotionImport.Source] = []
    @State private var loadingSources = false
    @State private var importing = false
    @State private var message: String?
    @State private var messageIsError = false

    private var hasToken: Bool {
        !settings.notionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SecureField("Internal Integration Secret", text: $settings.notionToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: settings.notionToken) {
                        sources = []
                        message = nil
                    }
                Link(destination: URL(string: "https://www.notion.so/profile/integrations")!) {
                    Label("Make a Notion integration", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("1. Connect Notion")
            } footer: {
                Text("Make a new internal integration called FlightLive, give it Read content access, and copy its Internal Integration Secret here. It's kept in your Keychain.")
            }

            Section {
                if !sources.isEmpty {
                    Picker("Flights database", selection: $settings.notionSourceID) {
                        Text("None").tag("")
                        ForEach(sources) { Text($0.title).tag($0.id) }
                    }
                    .onChange(of: settings.notionSourceID) { _, id in
                        settings.notionSourceTitle = sources.first { $0.id == id }?.title ?? ""
                    }
                } else if !settings.notionSourceID.isEmpty {
                    LabeledContent("Flights database", value: settings.notionSourceTitle)
                }
                Button {
                    Task { await loadSources() }
                } label: {
                    HStack {
                        Label(settings.notionSourceID.isEmpty ? "Find my databases" : "Choose another database", systemImage: "magnifyingglass")
                        Spacer()
                        if loadingSources { ProgressView() }
                    }
                }
                .disabled(!hasToken || loadingSources)
            } header: {
                Text("2. Pick your flights database")
            } footer: {
                Text("Only databases connected to the integration show up. In Notion, open your flights database, tap ••• › Connections, and add FlightLive.")
            }

            Section {
                Toggle("Import new flights automatically", isOn: $settings.notionAutoImport)
                Button {
                    importNow()
                } label: {
                    HStack {
                        Label("Import now", systemImage: "square.and.arrow.down")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(settings.notionSourceID.isEmpty || !hasToken || importing)
                if let message {
                    Label(message, systemImage: messageIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(messageIsError ? Color.flightRed : Color.flightGreen)
                }
            } header: {
                Text("3. Import")
            } footer: {
                Text("""
                FlightLive reads a Flight column (like 6E 978 or IndiGo 978), or a flight number in the page title, and a Date column. Put the time in the date if you know it. From, To, Seat, Booking and Gate columns are used when they're there.

                Upcoming flights are tracked live with alerts and reminders; past ones go to your Passport. Each page is imported once, so a flight you remove in FlightLive doesn't come back.
                """)
            }
        }
        .navigationTitle("Notion")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadSources() async {
        loadingSources = true
        message = nil
        do {
            sources = try await NotionImport.sources(token: settings.notionToken.trimmingCharacters(in: .whitespacesAndNewlines))
            if sources.isEmpty {
                show("No databases are connected yet. In Notion, open your flights database, tap ••• › Connections, and add FlightLive.", error: true)
            } else if sources.count == 1 {
                settings.notionSourceID = sources[0].id
                settings.notionSourceTitle = sources[0].title
            }
        } catch {
            show(error.localizedDescription, error: true)
        }
        loadingSources = false
    }

    private func importNow() {
        importing = true
        message = nil
        Task {
            do {
                let result = try await store.importFromNotion(force: true)
                var parts = ["Added \(result.added) flight\(result.added == 1 ? "" : "s")."]
                if result.alreadyHere > 0 { parts.append("\(result.alreadyHere) already here.") }
                if result.notFound > 0 { parts.append("Couldn't find \(result.notFound); check the flight number and date.") }
                show(parts.joined(separator: " "), error: result.added == 0 && result.notFound > 0)
            } catch {
                show(error.localizedDescription, error: true)
            }
            importing = false
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
