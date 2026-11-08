import SwiftUI

/// The forecast at the destination for when you land, from Open-Meteo (free, no key).
struct ArrivalWeather: Equatable {
    var temperature: Int
    var unit: String
    var code: Int

    /// WMO weather codes, as Open-Meteo reports them.
    var description: String {
        switch code {
        case 0: "Clear"
        case 1, 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...77: "Snow"
        case 80...82: "Showers"
        case 85, 86: "Snow showers"
        case 95...99: "Thunderstorms"
        default: "—"
        }
    }

    var symbol: String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 80...82: "cloud.heavyrain.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud"
        }
    }

    private static var cache: [String: ArrivalWeather] = [:]

    /// Nil for times more than about two weeks out (past the forecast) or already over.
    @MainActor
    static func forecast(for airport: FlightActivityAttributes.Airport, at date: Date, fahrenheit: Bool) async -> ArrivalWeather? {
        guard date > Date().addingTimeInterval(-3 * 3600), date < Date().addingTimeInterval(15 * 24 * 3600) else { return nil }
        let hour = Int(date.timeIntervalSince1970 / 3600)
        let key = "\(airport.code)-\(hour)-\(fahrenheit)"
        if let cached = cache[key] { return cached }

        let utc = TimeZone(identifier: "UTC")!
        let day = AeroDataBox.dayString(date, timeZone: utc)
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            .init(name: "latitude", value: String(airport.latitude)),
            .init(name: "longitude", value: String(airport.longitude)),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "timezone", value: "GMT"),
            .init(name: "start_date", value: day),
            .init(name: "end_date", value: day),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = components?.url,
              let (data, response) = try? await HTTP.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              let temperatures = hourly["temperature_2m"] as? [Double],
              let codes = hourly["weather_code"] as? [Int] else { return nil }

        // Times come as "2026-10-27T14:00" in GMT; take the hour the flight lands in.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let wanted = String(format: "%@T%02d:00", day, calendar.component(.hour, from: date))
        guard let index = times.firstIndex(of: wanted), index < temperatures.count, index < codes.count else { return nil }
        let weather = ArrivalWeather(temperature: Int(temperatures[index].rounded()), unit: fahrenheit ? "°F" : "°", code: codes[index])
        cache[key] = weather
        return weather
    }
}

/// "☁︎ 24° · Partly cloudy when you land"
struct ArrivalWeatherLine: View {
    var airport: FlightActivityAttributes.Airport
    var arrival: Date
    var fahrenheit: Bool
    @State private var weather: ArrivalWeather?

    var body: some View {
        Group {
            if let weather {
                Label {
                    Text("\(weather.temperature)\(weather.unit) · \(weather.description) when you land")
                } icon: {
                    Image(systemName: weather.symbol)
                        .symbolRenderingMode(.multicolor)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .task(id: "\(airport.code)-\(Int(arrival.timeIntervalSince1970 / 3600))-\(fahrenheit)") {
            weather = await ArrivalWeather.forecast(for: airport, at: arrival, fahrenheit: fahrenheit)
        }
    }
}
