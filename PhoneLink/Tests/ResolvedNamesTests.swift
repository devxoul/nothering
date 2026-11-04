import Foundation
import PhoneLink
import Testing

@Suite struct ResolvedNamesTests {
  private let publicAddress = Data([93, 184, 216, 34])
  private let overrideAddress = Data([203, 0, 113, 7])

  @Test func matchesOnlyAddressesTheResolverReturned() {
    let names = ResolvedNames()
    names.record([publicAddress], for: "example.com")
    #expect(names.contains(publicAddress, for: "example.com"))
    // An /etc/hosts override the Mac connected to, which the resolver never returned.
    #expect(!names.contains(overrideAddress, for: "example.com"))
    #expect(!names.contains(publicAddress, for: "example.org"))
  }

  @Test func ignoresCaseAndTrailingDot() {
    let names = ResolvedNames()
    names.record([publicAddress], for: "Example.COM.")
    #expect(names.contains(publicAddress, for: "example.com"))
  }

  @Test func accumulatesAnswersForTheSameName() {
    let names = ResolvedNames()
    names.record([publicAddress], for: "example.com")
    names.record([overrideAddress], for: "example.com")
    #expect(names.contains(publicAddress, for: "example.com"))
    #expect(names.contains(overrideAddress, for: "example.com"))
  }
}
