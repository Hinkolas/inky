#if DEBUG
import InkyCore

/// Made-up contacts, for looking at how they are found without anyone's
/// real ones, and without macOS asking to read them: read by a run with
/// `--data`. `--contacts notAsked|denied` says what such a run may do.
struct ContactSamples: ContactsReading {
    var access = ContactsAccess.allowed

    func requestAccess() async -> Bool { access == .allowed }

    func contacts() async throws -> [ContactRecord] {
        let people: [(String, String, String, String)] = [
            ("Thomas Albrecht", "Harbor Office", "thomas.albrecht@harbor.example", "+49 381 555 0142"),
            ("Thomas Becker", "", "tom@becker.example", "+49 171 555 0118"),
            ("Thea Lindqvist", "Northwind Sails", "thea@northwind.example", ""),
            ("Anna Thomsen", "", "", "+45 20 55 01 77"),
            ("Jonas Weber", "Harbor Office", "jonas.weber@harbor.example", "+49 381 555 0143"),
            ("Mara Okafor", "Tide & Co", "mara@tide.example", "+44 20 7946 0321"),
            ("Samira Haddad", "", "samira.haddad@mail.example", "+49 160 555 0199"),
            ("Luis Ortega", "Ortega Marine", "luis@ortega.example", "+34 91 555 0164"),
            ("Ingrid Solberg", "", "ingrid@solberg.example", ""),
            ("Pavel Novak", "Crane Works", "novak@craneworks.example", "+420 555 010 222"),
            ("Chiara Romano", "", "chiara.romano@mail.example", "+39 06 5550 1234"),
            ("Dr. Henrik Thomasson", "Thomasson Dental", "praxis@thomasson.example", "+46 8 555 010 55"),
        ]
        var records = people.enumerated().map { offset, person in
            ContactRecord(
                id: "sample-\(offset):ABPerson",
                name: person.0,
                nickname: person.0 == "Thomas Becker" ? "Tom" : "",
                organization: person.1,
                emails: person.2.isEmpty ? [] : [person.2],
                phones: person.3.isEmpty ? [] : [person.3]
            )
        }
        records.append(ContactRecord(
            id: "sample-org:ABPerson", name: "", organization: "Thompson Yacht Charter", isOrganization: true,
            emails: ["office@thompson-charter.example"], phones: ["+49 381 555 0100"]
        ))
        return records
    }
}
#endif
