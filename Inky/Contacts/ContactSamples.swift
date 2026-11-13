#if DEBUG
import AppKit
import InkyCore

/// Made-up contacts, for looking at how they are found without anyone's
/// real ones, and without macOS asking to read them: read by a run with
/// `--data`. `--contacts notAsked|denied` says what such a run may do.
struct ContactSamples: ContactsReading {
    var access = ContactsAccess.allowed

    private struct Person {
        var name: String
        var company = ""
        var job = ""
        var email = ""
        var phone = ""
        var groups: [String] = []
        var nickname = ""
        var birthday: DateComponents?
        var address = ""
    }

    private static let people: [Person] = [
        Person(name: "Thomas Albrecht", company: "Harbor Office", job: "Harbor Master", email: "thomas.albrecht@harbor.example",
               phone: "+49 381 555 0142", groups: ["Harbor", "Work"], birthday: DateComponents(year: 1978, month: 3, day: 14),
               address: "Am Strom 12, 18119 Rostock, Germany"),
        Person(name: "Thomas Becker", email: "tom@becker.example", phone: "+49 171 555 0118", groups: ["Sailing Club"],
               nickname: "Tom", birthday: DateComponents(month: 12, day: 24)),
        Person(name: "Thea Lindqvist", company: "Northwind Sails", job: "Sailmaker", email: "thea@northwind.example", groups: ["Work"]),
        Person(name: "Anna Thomsen", phone: "+45 20 55 01 77", groups: ["Sailing Club", "Family"]),
        Person(name: "Jonas Weber", company: "Harbor Office", job: "Berth Planning", email: "jonas.weber@harbor.example",
               phone: "+49 381 555 0143", groups: ["Harbor", "Work"]),
        Person(name: "Mara Okafor", company: "Tide & Co", job: "Hydrographer", email: "mara@tide.example", phone: "+44 20 7946 0321", groups: ["Work"]),
        Person(name: "Samira Haddad", email: "samira.haddad@mail.example", phone: "+49 160 555 0199", groups: ["Family"]),
        Person(name: "Luis Ortega", company: "Ortega Marine", email: "luis@ortega.example", phone: "+34 91 555 0164"),
        Person(name: "Ingrid Solberg", email: "ingrid@solberg.example", groups: ["Sailing Club"]),
        Person(name: "Pavel Novak", company: "Crane Works", job: "Crane Operator", email: "novak@craneworks.example", phone: "+420 555 010 222", groups: ["Harbor"]),
        Person(name: "Chiara Romano", email: "chiara.romano@mail.example", phone: "+39 06 5550 1234", groups: ["Family"]),
        Person(name: "Dr. Henrik Thomasson", company: "Thomasson Dental", email: "praxis@thomasson.example", phone: "+46 8 555 010 55"),
        Person(name: "Émile Aubert", company: "Aubert Voiles", email: "emile@aubert.example", groups: ["Work"]),
        Person(name: "Björn Åkesson", phone: "+46 70 555 01 23", groups: ["Sailing Club"]),
    ]

    private static func id(_ offset: Int) -> String { "sample-\(offset):ABPerson" }
    private static let companyID = "sample-org:ABPerson"

    func requestAccess() async -> Bool { access == .allowed }

    func contacts() async throws -> [ContactRecord] {
        var records = Self.people.enumerated().map { offset, person in
            ContactRecord(
                id: Self.id(offset),
                name: person.name,
                nickname: person.nickname,
                organization: person.company,
                emails: person.email.isEmpty ? [] : [person.email],
                phones: person.phone.isEmpty ? [] : [person.phone],
                groups: person.groups,
                hasPicture: Self.pictured.contains(offset)
            )
        }
        records.append(ContactRecord(
            id: Self.companyID, name: "", organization: "Thompson Yacht Charter", isOrganization: true,
            emails: ["office@thompson-charter.example"], phones: ["+49 381 555 0100"], groups: ["Harbor"]
        ))
        return records
    }

    /// The ones that have a picture: a photo, and one that is see-through
    /// around a face, as a Memoji is.
    private static let pictured: Set<Int> = [0, 1, 3, 5]

    func picture(of id: String) async -> Data? {
        guard let offset = Self.people.indices.first(where: { Self.id($0) == id }), Self.pictured.contains(offset) else { return nil }
        let side = 160
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let frame = NSRect(x: 0, y: 0, width: side, height: side)
        let isCutOut = offset == 1
        if !isCutOut {
            let skies: [[NSColor]] = [[.systemTeal, .systemIndigo], [.systemOrange, .systemPink], [.systemGreen, .systemTeal]]
            NSGradient(colors: skies[offset % skies.count])?.draw(in: frame, angle: 70)
        }
        // A head and shoulders.
        NSColor(calibratedRed: 0.93, green: 0.78, blue: 0.64, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 50, y: 62, width: 60, height: 68)).fill()
        NSColor(calibratedWhite: isCutOut ? 0.25 : 0.95, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 22, y: -62, width: 116, height: 116)).fill()
        NSColor(calibratedRed: 0.3, green: 0.2, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 46, y: 104, width: 68, height: 34)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    func details(of id: String) async -> ContactDetails? {
        if id == Self.companyID {
            return ContactDetails(
                id: id,
                phones: [.init("main", "+49 381 555 0100")],
                emails: [.init("work", "office@thompson-charter.example")],
                addresses: [.init("work", "Kai 4, 18119 Rostock, Germany")],
                links: [.init("homepage", "thompson-charter.example")]
            )
        }
        guard let offset = Self.people.indices.first(where: { Self.id($0) == id }) else { return nil }
        let person = Self.people[offset]
        var phones = person.phone.isEmpty ? [] : [ContactDetails.Entry("mobile", person.phone)]
        var emails = person.email.isEmpty ? [] : [ContactDetails.Entry(person.company.isEmpty ? "home" : "work", person.email)]
        // One with more of everything than the panel has room for.
        if offset == 0 {
            phones.append(.init("work", "+49 381 555 0140"))
            emails.append(.init("home", "thomas@albrecht.example"))
        }
        return ContactDetails(
            id: id,
            jobTitle: person.job,
            phones: phones,
            emails: emails,
            addresses: person.address.isEmpty ? [] : [.init("work", person.address)],
            birthday: person.birthday
        )
    }
}
#endif
