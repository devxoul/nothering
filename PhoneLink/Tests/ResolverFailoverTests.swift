import PhoneLink
import Testing

@Suite struct ResolverFailoverTests {
  @Test func triesResolversInOrderUntilOneAnswers() {
    let failover = ResolverFailover(["a", "b", "c"])
    var tried: [String] = []
    let answer: String? = failover.firstAnswer { resolver in
      tried.append(resolver)
      return resolver == "b" ? "answer" : nil
    }
    #expect(answer == "answer")
    #expect(tried == ["a", "b"])
  }

  @Test func startsWithTheLastResolverThatAnswered() {
    let failover = ResolverFailover(["a", "b", "c"])
    let _: String? = failover.firstAnswer { $0 == "b" ? $0 : nil }
    var tried: [String] = []
    let _: String? = failover.firstAnswer { resolver in
      tried.append(resolver)
      return resolver == "a" ? resolver : nil
    }
    #expect(tried == ["b", "c", "a"])
  }

  @Test func keepsThePreferredResolverWhenNoneAnswer() {
    let failover = ResolverFailover(["a", "b"])
    let _: String? = failover.firstAnswer { $0 == "b" ? $0 : nil }
    let none: String? = failover.firstAnswer { _ in nil }
    #expect(none == nil)
    var tried: [String] = []
    let _: String? = failover.firstAnswer { resolver in
      tried.append(resolver)
      return resolver
    }
    #expect(tried == ["b"])
  }
}
