#!/usr/bin/env swift
// Round 14 A4 fix round 1 (owner, 2026-11-04): writes App/Resources/ChartPlaylists.json, the Deezer "Top <Country>"
// chart playlist for each country, so Trending can show any country's top songs **through the user's Aurral**
// (`GET /api/discover/editorial/<id>`). The app never calls Deezer: this script is run by hand at dev time only.
//
// Aurral 2.13.0's own rule (backend/services/discovery/trendingCharts.ts, findChartPlaylist / chartPlaylistTitle):
// the playlists of Deezer's charts user 637006841 titled "Top <English region name>", with Deezer's own names for a few
// (DEEZER_REGION_NAMES). Read-only public GETs; nothing is sent but the paging query.
//
// Usage: swift scripts/gen-chart-playlists.swift > App/Resources/ChartPlaylists.json
import Foundation

let chartsUser = 637006841
let deezerNames = ["US": "USA", "GB": "UK", "CZ": "Czech Republic", "CI": "Ivory Coast", "TR": "Turkey"]
let english = Locale(identifier: "en")

func get(_ url: URL) throws -> [String: Any] {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error> = .failure(URLError(.unknown))
    URLSession.shared.dataTask(with: url) { data, _, error in
        result = data.map { .success($0) } ?? .failure(error ?? URLError(.badServerResponse))
        semaphore.signal()
    }.resume()
    semaphore.wait()
    guard let object = try JSONSerialization.jsonObject(with: try result.get()) as? [String: Any] else {
        throw URLError(.cannotParseResponse)
    }
    return object
}

var titles: [String: String] = [:]   // title → playlist id
var index = 0
while index < 2_000 {
    let page = try get(URL(string: "https://api.deezer.com/user/\(chartsUser)/playlists?index=\(index)&limit=100")!)
    let items = page["data"] as? [[String: Any]] ?? []
    for item in items {
        guard let title = item["title"] as? String, let id = item["id"] else { continue }
        if titles[title] == nil { titles[title] = "\(id)" }
    }
    if items.isEmpty || page["next"] == nil { break }
    index += 100
}

var charts: [String: String] = [:]
for code in Locale.Region.isoRegions.map(\.identifier) where code.count == 2 {
    guard let name = deezerNames[code] ?? english.localizedString(forRegionCode: code) else { continue }
    if let id = titles["Top \(name)"], id.allSatisfy(\.isNumber) { charts[code] = id }
}

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd"
let file: [String: Any] = [
    "generated": formatter.string(from: Date()),
    "source": "Deezer charts user \(chartsUser), playlists titled \"Top <Country>\" (Aurral 2.13.0 chartPlaylistTitle)",
    "worldwide": titles["Top Worldwide"] ?? NSNull(),
    "charts": charts,
]
let data = try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
