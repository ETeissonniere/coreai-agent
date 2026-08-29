import Testing
@testable import QwenCoreAI

@Test func conversationScrollFollowsWhileContentGrowsAtTheBottom() {
    var state = ConversationScrollState()
    state.observe(.init(offset: 500, distanceFromBottom: 0))

    // Streaming adds content below the viewport before the next scroll-to-bottom.
    state.observe(.init(offset: 500, distanceFromBottom: 40))

    #expect(state.isFollowingLatest)
}

@Test func conversationScrollStopsFollowingAfterUserScrollsUp() {
    var state = ConversationScrollState()
    state.observe(.init(offset: 500, distanceFromBottom: 0))
    state.observe(.init(offset: 380, distanceFromBottom: 120))

    #expect(!state.isFollowingLatest)

    // More streamed content must not implicitly re-enable following.
    state.observe(.init(offset: 380, distanceFromBottom: 300))
    #expect(!state.isFollowingLatest)
}

@Test func conversationScrollResumesNearBottomOrOnExplicitRequest() {
    var state = ConversationScrollState()
    state.observe(.init(offset: 500, distanceFromBottom: 0))
    state.observe(.init(offset: 300, distanceFromBottom: 200))
    #expect(!state.isFollowingLatest)

    state.observe(.init(offset: 430, distanceFromBottom: 60))
    #expect(state.isFollowingLatest)

    state.observe(.init(offset: 300, distanceFromBottom: 200))
    state.resumeFollowing()
    #expect(state.isFollowingLatest)
}
