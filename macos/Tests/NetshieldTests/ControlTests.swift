import Foundation
import Testing
@testable import NetshieldCore

struct ControlTests {
    @Test func touchIDPromptSaysWhatChanges() throws {
        let configuration = try policySnapshot(.blockAll, generation: 4)
        #expect(ControlAction.start(configuration).reason
            == "netshield: start filtering (mode block-all, 2 allow rules, 0 hooks, generation 4)")
        #expect(ControlAction.stop.reason == "netshield: stop filtering and deactivate the network extension")
        #expect(ControlAction.mode(from: .acceptAll, to: .blockAll, generation: 5).reason
            == "netshield: change the mode from accept-all to block-all (generation 5)")
        let tool = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345"))
        #expect(ControlAction.approve(tool, host: "example.com", seconds: 3600).reason
            == "netshield: let ABCDE12345/com.example.tool reach example.com for 1 h")
        let build = AppIdentity.cdhash(String(repeating: "0f", count: 20))
        #expect(ControlAction.approve(build, host: "example.com", seconds: 600).reason
            == "netshield: let cdhash/\(String(repeating: "0f", count: 20)) reach example.com for 10 min")
        #expect(ControlAction.deny(tool, host: "example.com").reason
            == "netshield: deny ABCDE12345/com.example.tool reaching example.com and drop its waiting connections")
        #expect(ControlAction.duration(45) == "45 s" && ControlAction.duration(90) == "90 s")
        #expect(ControlAction.duration(5400) == "1 h 30 min" && ControlAction.duration(86_400) == "24 h")
    }

    @Test func replacementNeverGoesBack() {
        let id = NetshieldIdentifiers.filter
        func allowed(_ existing: String, _ candidate: String) -> Bool {
            ExtensionReplacement.allowed(existingID: id, existingVersion: existing, candidateID: id, candidateVersion: candidate)
        }
        #expect(allowed("1", "1"))
        #expect(allowed("1", "2"))
        #expect(allowed("1", "1.0"))
        #expect(allowed("1.2.3", "1.10"))
        #expect(!allowed("2", "1"))
        #expect(!allowed("1.10", "1.9.9"))
        for bad in ["", "1.", ".1", "a", "1.2.3.4", "-1", "1 ", "1234567890", "１"] {
            #expect(!allowed("1", bad), "candidate \(bad)")
            #expect(!allowed(bad, "1"), "existing \(bad)")
        }
        #expect(!ExtensionReplacement.allowed(existingID: "com.example.other", existingVersion: "1",
                                              candidateID: id, candidateVersion: "2"))
        #expect(!ExtensionReplacement.allowed(existingID: id, existingVersion: "1",
                                              candidateID: "com.example.other", candidateVersion: "2"))
        #expect(ExtensionReplacement.version("1.0.0") == [1])
        #expect(ExtensionReplacement.version("0") == [])
    }

    @Test func foreignFiltersAreLeftAlone() throws {
        #expect(SavedFilter(providerBundleID: nil, enabled: false, configuration: nil).foreignOwner == nil)
        #expect(SavedFilter(providerBundleID: NetshieldIdentifiers.filter, enabled: true,
                            configuration: try policySnapshot(.ask)).foreignOwner == nil)
        #expect(SavedFilter(providerBundleID: "com.example.vpn.filter", enabled: true, configuration: nil).foreignOwner
            == "com.example.vpn.filter")
    }

    @Test func identifiersMatchTheBundles() {
        #expect(NetshieldIdentifiers.host == "com.valentorassa.netshield")
        #expect(NetshieldIdentifiers.filter == NetshieldIdentifiers.host + ".filter")
        #expect(NetshieldIdentifiers.providerClass == "NetshieldFilterDataProvider")
    }
}
