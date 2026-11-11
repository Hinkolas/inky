// Makes InkyCore's list of places from GeoNames' "cities15000.txt":
//
//     swift Scripts/places.swift cities15000.txt > InkyCore/Sources/InkyCore/Resources/places.tsv
//
// `make places` downloads the file and does this.
//
// A line is a city: its name, the code of its country, its time zone, and
// its name in plain letters where that is not just the name without accents.
// Cities come largest first, and a name that several share is kept for the
// largest only. A line that starts with "@" is a country nearly all of whose
// people live in one time zone: its code and that zone.

import Foundation

guard CommandLine.arguments.count == 2,
      let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
else {
    FileHandle.standardError.write(Data("usage: swift Scripts/places.swift cities15000.txt\n".utf8))
    exit(1)
}

struct City {
    var name: String
    var plain: String
    var country: String
    var zone: String
    var population: Int
    var isCapital: Bool
}

/// The smallest city that is listed, unless it is a capital.
let minimumPopulation = 100_000
/// The share of a country's people that makes one time zone the country's.
let countryShare = 0.9

func key(_ name: String) -> String {
    name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: " ")
}

var cities: [City] = []
for line in text.split(separator: "\n") {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 18, let population = Int(fields[14]), !fields[17].isEmpty, !fields[8].isEmpty else { continue }
    cities.append(City(
        name: fields[1], plain: fields[2], country: fields[8], zone: fields[17],
        population: population, isCapital: fields[7] == "PPLC"
    ))
}
guard !cities.isEmpty else {
    FileHandle.standardError.write(Data("No valid cities found in the GeoNames input\n".utf8))
    exit(1)
}
cities.sort { ($0.population, $1.name) > ($1.population, $0.name) }

var lines: [String] = []
var taken: Set<String> = []
for city in cities where city.population >= minimumPopulation || city.isCapital {
    guard taken.insert(key(city.name)).inserted else { continue }
    var fields = [city.name, city.country, city.zone]
    if key(city.plain) != key(city.name), taken.insert(key(city.plain)).inserted {
        fields.append(city.plain)
    }
    lines.append(fields.joined(separator: "\t"))
}

var populations: [String: [String: Int]] = [:]
for city in cities {
    populations[city.country, default: [:]][city.zone, default: 0] += city.population
}
for (country, zones) in populations.sorted(by: { $0.key < $1.key }) {
    let total = zones.values.reduce(0, +)
    guard total > 0, let (zone, people) = zones.max(by: { $0.value < $1.value }),
          Double(people) >= countryShare * Double(total)
    else { continue }
    lines.append("@\(country)\t\(zone)")
}

print(lines.joined(separator: "\n"))
