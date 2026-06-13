import Testing
@testable import TermPilot

struct ProfileSearchTests {
    @Test func emptySearchQueryMatchesEverything() {
        #expect(ProfileSearch.matches("", fields: []))
        #expect(ProfileSearch.matches("   ", fields: ["Production"]))
    }

    @Test func searchMatchesAcrossFieldsCaseInsensitively() {
        #expect(ProfileSearch.matches("prod", fields: ["Production Server", "10.0.0.1"]))
        #expect(ProfileSearch.matches("ROOT", fields: ["prod.example.com", "root"]))
        #expect(!ProfileSearch.matches("staging", fields: ["Production Server", "10.0.0.1"]))
    }

    @Test func searchIgnoresDiacritics() {
        #expect(ProfileSearch.matches("cafe", fields: ["Café Vault"]))
    }
}
