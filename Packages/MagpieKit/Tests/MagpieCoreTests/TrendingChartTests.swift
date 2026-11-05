import Foundation
import Testing
@testable import MagpieCore

/// Round 15 C2 (owner items 5 and 5b, D132): Trending's chart picker. A chart is Worldwide, a country (any, from the
/// bundled list) or a genre chart; one is the default Trending always opens on (stored in the existing Charts country
/// setting, which grows Worldwide and a genre).
@Suite struct TrendingChartTests {
    @Test func aChartsKeyRoundTrips() {
        for chart in [TrendingChart.worldwide, .country("AU"), .country("US"), .genre(132), .genre(0)] {
            #expect(TrendingChart(key: chart.key) == chart, "\(chart.key)")
        }
        #expect(TrendingChart.country("de").key == "country:DE", "codes are upper-cased")
        for bad in ["", "country:", "country:XYZ", "country:1A", "genre:", "genre:x", "genre:-1", "genre:1234567", "worldwide:x",
                    "server", "automatic"] {
            #expect(TrendingChart(key: bad) == nil, "\(bad)")
        }
    }

    /// The default chart is the Charts country setting: Worldwide and a genre are stored as "worldwide" and
    /// "genre:<id>"; older builds' "automatic", "server" and ISO codes read as before.
    @Test func theDefaultChartIsStoredInChartsCountry() throws {
        for (stored, expected) in [("\"worldwide\"", ChartsCountry.worldwide), ("\"genre:132\"", .genre(132)),
                                   ("\"genre:x\"", .automatic), ("\"genre:-4\"", .automatic), ("\"server\"", .server),
                                   ("\"AU\"", .country("AU"))] {
            let json = #"{"chartsCountry":\#(stored)}"#
            #expect(LayoutPreferences.decode(Data(json.utf8)).chartsCountry == expected, "\(stored)")
        }
        var layout = LayoutPreferences.defaultValue
        layout.chartsCountry = .worldwide
        #expect(LayoutPreferences.decode(try #require(layout.encoded())).chartsCountry == .worldwide)
        layout.chartsCountry = .genre(116)
        #expect(LayoutPreferences.decode(try #require(layout.encoded())).chartsCountry == .genre(116))
        #expect(ChartsCountry(chart: .worldwide) == .worldwide && ChartsCountry(chart: .country("jp")) == .country("JP")
                && ChartsCountry(chart: .genre(152)) == .genre(152))
    }

    /// Which chart a setting opens on: Automatic is the phone's region when it has a chart, else the server's; Server
    /// is the server's region (nil when the server didn't say: its own chart); a picked chart is itself.
    @Test func whichChartTheDefaultOpensOn() {
        let charts: Set<String> = ["AU", "US", "DE"]
        #expect(ChartsCountry.automatic.chart(phoneRegion: "US", serverRegion: "AU", countriesWithCharts: charts) == .country("US"))
        #expect(ChartsCountry.automatic.chart(phoneRegion: "NZ", serverRegion: "AU", countriesWithCharts: charts) == .country("AU"))
        #expect(ChartsCountry.automatic.chart(phoneRegion: nil, serverRegion: nil, countriesWithCharts: charts) == nil)
        #expect(ChartsCountry.server.chart(phoneRegion: "US", serverRegion: "au", countriesWithCharts: charts) == .country("AU"))
        #expect(ChartsCountry.country("DE").chart(phoneRegion: "US", serverRegion: "AU", countriesWithCharts: charts) == .country("DE"))
        #expect(ChartsCountry.worldwide.chart(phoneRegion: "US", serverRegion: "AU", countriesWithCharts: charts) == .worldwide)
        #expect(ChartsCountry.genre(132).chart(phoneRegion: nil, serverRegion: nil, countriesWithCharts: charts) == .genre(132))
    }
}
