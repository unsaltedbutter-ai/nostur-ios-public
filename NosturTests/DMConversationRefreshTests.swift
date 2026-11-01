//
//  DMConversationRefreshTests.swift
//  NosturTests
//
//  Regression tests for refreshing an open DM conversation:
//  - a re-apply of unchanged local messages must reuse the rendered ConversationYear /
//    ConversationDay / NRChatMessage instances (no full remount, no blank flash)
//  - runtime state on rendered messages (reactions, dmSendResult) must survive a re-apply
//  - load(force: true) must not downgrade an already rendered conversation to .loading
//  - a structural no-op must not reassign viewState at all
//

import Foundation
import Combine
import CoreData
import NostrEssentials
import Testing
@testable import Nostur

@Suite("DM conversation refresh", .serialized)
@MainActor
struct DMConversationRefreshTests {

    // MARK: - (a) instance reuse across a re-apply

    @Test("Re-applying refreshed local messages reuses year, day and message instances")
    func reapplyReusesRenderedInstances() async throws {
        _ = AppState.shared
        _ = AccountsState.shared
        let fixture = try await DMRefreshFixture()
        let vm = fixture.makeVM()
        await vm.load()

        let yearsBefore = renderedYears(vm)
        let daysBefore = renderedDays(vm)
        let messagesBefore = renderedMessages(vm)
        #expect(yearsBefore.count == 2)
        #expect(daysBefore.count >= 2)
        #expect(messagesBefore.count == 3)

        let yearIdentities = yearsBefore.map { ObjectIdentifier($0) }
        let dayIdentities = daysBefore.map { ObjectIdentifier($0) }
        let messageIdentities = messagesBefore.map { ($0.id, ObjectIdentifier($0)) }

        // Add one message on a day that is already rendered: the re-apply updates that day in place.
        let anAlreadyRenderedDate = try #require(messagesBefore.first?.createdAt)
        let lastDayStart = Calendar.current.startOfDay(for: anAlreadyRenderedDate)
        let extraId = await fixture.insertMessage(timestamp: Int(lastDayStart.timeIntervalSince1970) + 60)

        vm.applyVisibleMessages(await fixture.freshChatMessages())

        #expect(renderedYears(vm).map { ObjectIdentifier($0) } == yearIdentities)
        #expect(renderedDays(vm).map { ObjectIdentifier($0) } == dayIdentities)

        let identitiesAfter = Dictionary(uniqueKeysWithValues: renderedMessages(vm).map { ($0.id, ObjectIdentifier($0)) })
        for (id, identity) in messageIdentities {
            #expect(identitiesAfter[id] == identity)
        }
        #expect(identitiesAfter[extraId] != nil)

        // Add one more message on a brand new day: this forces a rebuild of the day/year hierarchy,
        // which must still reuse the instances that were already on screen.
        let newDayId = await fixture.insertMessage(timestamp: Int(lastDayStart.timeIntervalSince1970) + 3 * 86_400 + 60)
        vm.applyVisibleMessages(await fixture.freshChatMessages())

        let yearsAfter = renderedYears(vm)
        let daysAfter = renderedDays(vm)
        #expect(Set(yearsAfter.map { ObjectIdentifier($0) }).isSuperset(of: Set(yearIdentities)))
        #expect(Set(daysAfter.map { ObjectIdentifier($0) }).isSuperset(of: Set(dayIdentities)))
        #expect(daysAfter.count == daysBefore.count + 1)
        #expect(renderedMessages(vm).contains { $0.id == newDayId })
        #expect(vm.onScreenIds == Set(fixture.messageIds + [extraId, newDayId]))

        await fixture.cleanup()
    }

    // MARK: - (b) no .loading downgrade when content is already rendered

    @Test("load(force: true) keeps .ready content and only swaps in place")
    func forcedReloadDoesNotShowSpinner() async throws {
        _ = AppState.shared
        _ = AccountsState.shared
        let fixture = try await DMRefreshFixture()
        let vm = fixture.makeVM()
        await vm.load()

        let yearsBefore = renderedYears(vm).map { ObjectIdentifier($0) }
        let messageIdentities = renderedMessages(vm).map { ObjectIdentifier($0) }
        #expect(!yearsBefore.isEmpty)

        var sawLoading = false
        let cancellable = vm.$viewState
            .dropFirst()
            .sink { state in
                if case .loading = state {
                    sawLoading = true
                }
            }

        await vm.load(force: true)
        cancellable.cancel()

        #expect(!sawLoading)
        let isReady: Bool = if case .ready = vm.viewState { true } else { false }
        #expect(isReady)
        // Same objects on screen, so SwiftUI does not tear down and remount the conversation.
        #expect(renderedYears(vm).map { ObjectIdentifier($0) } == yearsBefore)
        #expect(renderedMessages(vm).map { ObjectIdentifier($0) } == messageIdentities)

        await fixture.cleanup()
    }

    // MARK: - (c) runtime state survives a re-apply

    @Test("Reactions and dmSendResult survive a re-apply on the same message instances")
    func runtimeStateSurvivesReapply() async throws {
        _ = AppState.shared
        _ = AccountsState.shared
        let fixture = try await DMRefreshFixture()
        let vm = fixture.makeVM()
        await vm.load()

        let messages = renderedMessages(vm)
        #expect(messages.count == 3)
        let reactedMessage = try #require(messages.first(where: { $0.pubkey == fixture.theirPubkey }))
        let outgoingMessage = try #require(messages.first(where: { $0.pubkey == fixture.ourPubkey }))

        let reactionEvent = NEvent(
            id: String(repeating: "b", count: 63) + "1",
            publicKey: fixture.theirPubkey,
            createdAt: NTimestamp(timestamp: 1_685_622_000),
            content: "🤙",
            kind: .reaction,
            tags: [],
            signature: ""
        )
        reactedMessage.addReaction(reactionEvent)
        outgoingMessage.dmSendResult[fixture.theirPubkey] = RecipientResult(
            recipientPubkey: fixture.theirPubkey,
            relayResults: ["wss://dm.example.invalid": .sending]
        )
        #expect(reactedMessage.reactions.count == 1)
        #expect(outgoingMessage.dmSendResult[fixture.theirPubkey] != nil)

        let identities = messages.map { ($0.id, ObjectIdentifier($0)) }

        vm.applyVisibleMessages(await fixture.freshChatMessages())

        let messagesAfter = renderedMessages(vm)
        let afterById = Dictionary(uniqueKeysWithValues: messagesAfter.map { ($0.id, $0) })
        for (id, identity) in identities {
            #expect(afterById[id].map { ObjectIdentifier($0) } == identity)
        }

        let reactedAfter = try #require(afterById[reactedMessage.id])
        let outgoingAfter = try #require(afterById[outgoingMessage.id])
        #expect(reactedAfter.reactions.contains(where: { $0.id == reactionEvent.id }))
        #expect(reactedAfter.reactions.first(where: { $0.id == reactionEvent.id })?.content == "🤙")
        #expect(outgoingAfter.dmSendResult[fixture.theirPubkey] != nil)

        await fixture.cleanup()
    }

    // MARK: - (d) identical re-apply is a structural no-op

    @Test("An identical message set does not reassign viewState")
    func identicalReapplyDoesNotReassignViewState() async throws {
        _ = AppState.shared
        _ = AccountsState.shared
        let fixture = try await DMRefreshFixture()
        let vm = fixture.makeVM()
        await vm.load()

        let yearsBefore = renderedYears(vm).map { ObjectIdentifier($0) }
        let daysBefore = renderedDays(vm).map { ObjectIdentifier($0) }
        #expect(!yearsBefore.isEmpty)

        var viewStateEmissions = 0
        let cancellable = vm.$viewState
            .dropFirst()
            .sink { _ in viewStateEmissions += 1 }

        vm.applyVisibleMessages(await fixture.freshChatMessages())
        cancellable.cancel()

        #expect(viewStateEmissions == 0)
        #expect(renderedYears(vm).map { ObjectIdentifier($0) } == yearsBefore)
        #expect(renderedDays(vm).map { ObjectIdentifier($0) } == daysBefore)
        #expect(vm.onScreenIds == Set(fixture.messageIds))

        await fixture.cleanup()
    }
}

// MARK: - Fixture

@MainActor
private final class DMRefreshFixture {
    let ourPubkey: String
    let theirPubkey: String
    let participants: Set<String>
    let conversationId: String
    let messageIds: [String]
    private let dmState: CloudDMState

    // Two calendar days in two calendar years, three messages, all kind 14 (NIP-17 rumor).
    private static let timestamps = [1_685_613_600, 1_685_619_000, 1_717_236_000]

    init() async throws {
        let timestamps = DMRefreshFixture.timestamps
        let ourKeys = try Keys.newKeys()
        let theirKeys = try Keys.newKeys()
        let ourPubkey = ourKeys.publicKeyHex
        let theirPubkey = theirKeys.publicKeyHex
        let participants: Set<String> = [ourPubkey, theirPubkey]
        let conversationId = CloudDMState.getConversationId(for: participants)
        let messageIds = (0..<timestamps.count).map { _ in DMRefreshFixture.randomHexId() }

        // The conversation state lives in the main context, exactly like getGroupState() expects.
        let context = viewContext()
        let dmState = CloudDMState(context: context)
        dmState.accountPubkey_ = ourPubkey
        dmState.participantPubkeys = participants
        dmState.contactPubkey_ = theirPubkey
        dmState.accepted = true
        dmState.version = 17
        dmState.disappearingMessagesSetting = .off
        dmState.lastMessageTimestamp_ = Date(timeIntervalSince1970: TimeInterval(timestamps.last!))
        try context.save()

        // Stored messages are what load()/getMessages() fetch; save them to the store first.
        let taskContext = DataProvider.shared().newTaskContext()
        try await taskContext.perform {
            for (index, timestamp) in timestamps.enumerated() {
                let nEvent = NEvent(
                    id: messageIds[index],
                    publicKey: index == 2 ? ourPubkey : theirPubkey,
                    createdAt: NTimestamp(timestamp: timestamp),
                    content: "message \(index)",
                    kind: .directMessage,
                    tags: [],
                    signature: ""
                )
                let event = Event.fromNEvent(nEvent: nEvent, context: taskContext)
                event.groupId = conversationId
            }
            try taskContext.save()
        }

        self.ourPubkey = ourPubkey
        self.theirPubkey = theirPubkey
        self.participants = participants
        self.conversationId = conversationId
        self.messageIds = messageIds
        self.dmState = dmState
    }

    func makeVM() -> ConversionVM {
        ConversionVM(
            participants: participants,
            ourAccountPubkey: ourPubkey,
            parentDMsVM: DMsVM(accountPubkey: ourPubkey)
        )
    }

    // Adds one more stored kind-14 message and returns its id.
    func insertMessage(timestamp: Int) async -> String {
        let id = DMRefreshFixture.randomHexId()
        let conversationId = self.conversationId
        let theirPubkey = self.theirPubkey
        let taskContext = DataProvider.shared().newTaskContext()
        await taskContext.perform {
            let nEvent = NEvent(
                id: id,
                publicKey: theirPubkey,
                createdAt: NTimestamp(timestamp: timestamp),
                content: "extra message",
                kind: .directMessage,
                tags: [],
                signature: ""
            )
            let event = Event.fromNEvent(nEvent: nEvent, context: taskContext)
            event.groupId = conversationId
            try? taskContext.save()
        }
        return id
    }

    // Fresh NRChatMessage instances for the same stored rows, mirroring what a local reload produces.
    func freshChatMessages() async -> [NRChatMessage] {
        let conversationId = self.conversationId
        return await withBgContext { bgContext in
            let request = NSFetchRequest<Event>(entityName: "Event")
            request.predicate = NSPredicate(format: "groupId = %@ AND kind IN {4,14,15}", conversationId)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Event.created_at, ascending: true)]
            return ((try? bgContext.fetch(request)) ?? []).map { event in
                NRChatMessage(
                    nEvent: NEvent(
                        id: event.id,
                        publicKey: event.pubkey,
                        createdAt: NTimestamp(timestamp: event.created_at),
                        content: event.content ?? "",
                        kind: NEventKind(id: event.kind),
                        tags: event.tags(),
                        signature: ""
                    ),
                    keyPair: nil
                )
            }
        }
    }

    func cleanup() async {
        let conversationId = self.conversationId

        let taskContext = DataProvider.shared().newTaskContext()
        await taskContext.perform {
            let request = NSFetchRequest<Event>(entityName: "Event")
            request.predicate = NSPredicate(format: "groupId == %@", conversationId)
            for event in (try? taskContext.fetch(request)) ?? [] {
                taskContext.delete(event)
            }
            try? taskContext.save()
        }

        let context = viewContext()
        if dmState.managedObjectContext != nil {
            context.delete(dmState)
            try? context.save()
        }
    }

    private static func randomHexId() -> String {
        String((0..<64).map { _ in "0123456789abcdef".randomElement()! })
    }
}

// MARK: - Rendered state helpers

@MainActor
private func renderedYears(_ vm: ConversionVM) -> [ConversationYear] {
    guard case .ready(let years) = vm.viewState else { return [] }
    return years
}

@MainActor
private func renderedDays(_ vm: ConversionVM) -> [ConversationDay] {
    renderedYears(vm).flatMap { $0.days }
}

@MainActor
private func renderedMessages(_ vm: ConversionVM) -> [NRChatMessage] {
    renderedDays(vm).flatMap { $0.messages }
}
