import Testing
import Foundation
import EmulatorKit
@testable import ControllerModel

private typealias SlotChange = PlayerAssignment.SlotChange

@Suite struct PlayerAssignmentTests {
    // MARK: - Fixtures

    private let game = "Doom"
    private let otherGame = "Quake"
    private let system = "PC"
    private let otherSystem = "PS1"

    /// A distinct pad per serial, so two pads in a test are never the same controller.
    private func pad(_ serial: String) -> ControllerID {
        ControllerID(family: .xboxOne, serial: serial, vidPid: 0x045E, transport: .usb)
    }

    // MARK: - The shape of a game's slots

    @Test func everyGameOffersEightSlots() {
        #expect(PlayerAssignment.slotCount == 8)
        #expect(PlayerAssignment.slotRange == 1...8)
        // A game nobody has played still has its eight slots, numbered as the UI shows them.
        let slots = PlayerAssignment().slots(game: game, system: system)
        #expect(slots.count == 8)
        #expect(slots.map(\.number) == Array(1...8))
        #expect(slots.allSatisfy { $0.isFree })
    }

    @Test func aClaimedSlotNamesItsHolder() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(slot: 2, for: pad("a"), game: game, system: system) == .claimed(slot: 2))
        let slots = assignment.slots(game: game, system: system)
        #expect(slots[1].controller == pad("a"))
        #expect(!slots[1].isFree)
        #expect(slots[1].isAwaitingReconnect == false)
        // The other seven slots are untouched.
        #expect(slots.filter { $0.number != 2 }.allSatisfy { $0.isFree })
        #expect(!assignment.isSlotAvailable(2, game: game, system: system))
        #expect((1...8).filter { assignment.isSlotAvailable($0, game: game, system: system) } == [1, 3, 4, 5, 6, 7, 8])
    }

    // MARK: - Claiming a named slot

    @Test func claimingAFreeSlotTakesIt() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(slot: 1, for: pad("a"), game: game, system: system) == .claimed(slot: 1))
        #expect(assignment.controller(in: 1, game: game, system: system) == pad("a"))
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == 1)
        #expect(!assignment.isSlotAvailable(1, game: game, system: system))
    }

    @Test func theClaimedSlotIsTheOneThatWasAskedFor() {
        let assignment = PlayerAssignment()
        // Not the first free slot: the slot asked for.
        #expect(assignment.claim(slot: 6, for: pad("a"), game: game, system: system) == .claimed(slot: 6))
        #expect(assignment.controller(in: 6, game: game, system: system) == pad("a"))
        #expect(assignment.controller(in: 1, game: game, system: system) == nil)
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == 6)
    }

    @Test func aSlotAnotherControllerHoldsIsRefused() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(slot: 3, for: pad("a"), game: game, system: system) == .claimed(slot: 3))
        #expect(assignment.claim(slot: 3, for: pad("b"), game: game, system: system) == .refused(.slotHeldByOtherController))
        // The holder keeps it.
        #expect(assignment.controller(in: 3, game: game, system: system) == pad("a"))
        #expect(assignment.slot(for: pad("b"), game: game, system: system) == nil)
    }

    @Test func claimingASlotTheSameControllerHoldsChangesNothing() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(slot: 4, for: pad("a"), game: game, system: system) == .claimed(slot: 4))
        #expect(assignment.claim(slot: 4, for: pad("a"), game: game, system: system) == .alreadyAssigned(slot: 4))
        #expect(assignment.controller(in: 4, game: game, system: system) == pad("a"))
    }

    @Test func aSlotTheSameControllerHeldThatWentAwayIsTakenBack() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 2, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))
        // The pad is back and names its own slot, so it takes it back rather than being refused.
        #expect(assignment.claim(slot: 2, for: pad("a"), game: game, system: system) == .claimed(slot: 2))
        #expect(assignment.disconnectedSlots(game: game, system: system).isEmpty)
        #expect(assignment.slots(game: game, system: system)[1].isAwaitingReconnect == false)
    }

    @Test func onePadCanHoldTwoSlotsInOneGame() {
        let assignment = PlayerAssignment()
        // Naming a slot is a request for that slot, so a pad already in the game may take another.
        #expect(assignment.claim(slot: 1, for: pad("a"), game: game, system: system) == .claimed(slot: 1))
        #expect(assignment.claim(slot: 4, for: pad("a"), game: game, system: system) == .claimed(slot: 4))
        // The slot it is known by is the lowest it holds.
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == 1)
        #expect(assignment.controller(in: 4, game: game, system: system) == pad("a"))
    }

    @Test func slotsOutsideTheRangeAreRefused() {
        let assignment = PlayerAssignment()
        // The slots a game offers are 1 to 8, so 0 and 9 name no slot at all.
        #expect(assignment.claim(slot: 0, for: pad("a"), game: game, system: system) == .refused(.slotOutOfRange))
        #expect(assignment.claim(slot: 9, for: pad("a"), game: game, system: system) == .refused(.slotOutOfRange))
        #expect(!assignment.isSlotAvailable(0, game: game, system: system))
        #expect(!assignment.isSlotAvailable(9, game: game, system: system))
        #expect(assignment.controller(in: 0, game: game, system: system) == nil)
        #expect(assignment.controller(in: 9, game: game, system: system) == nil)
        // A release out of range touches nothing, so the table is left as it was.
        assignment.release(slot: 9, game: game, system: system)
        #expect(assignment.slots(game: game, system: system).allSatisfy { $0.isFree })
    }

    @Test func allEightSlotsCanBeClaimed() {
        let assignment = PlayerAssignment()
        for number in 1...8 {
            #expect(assignment.claim(slot: number, for: pad("pad\(number)"), game: game, system: system) == .claimed(slot: number))
        }
        let slots = assignment.slots(game: game, system: system)
        #expect(slots.count == 8)
        #expect(slots.map(\.number) == Array(1...8))
        #expect(slots.allSatisfy { !$0.isFree })
        // Each pad is in the slot it asked for.
        for number in 1...8 {
            #expect(assignment.controller(in: number, game: game, system: system) == pad("pad\(number)"))
        }
        // A ninth pad has nowhere to go.
        #expect(assignment.claim(button: .east, for: pad("nine"), game: game, system: system) == .noFreeSlot)
    }

    @Test func aFullGameRefusesEverySlot() {
        let assignment = PlayerAssignment()
        for number in 1...8 {
            assignment.claim(slot: number, for: pad("pad\(number)"), game: game, system: system)
        }
        // Every slot has an owner, so a claim of a named slot is refused, not granted.
        #expect(assignment.claim(slot: 4, for: pad("nine"), game: game, system: system) == .refused(.slotHeldByOtherController))
        #expect(assignment.controller(in: 4, game: game, system: system) == pad("pad4"))
    }

    // MARK: - Claiming by button press

    @Test func aButtonPressTakesTheLowestFreeSlot() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(button: .south, for: pad("a"), game: game, system: system) == .claimed(slot: 1))
        #expect(assignment.claim(button: .south, for: pad("b"), game: game, system: system) == .claimed(slot: 2))
        // A pad that already holds a slot ignores the press, so the game still sees the button.
        #expect(assignment.claim(button: .south, for: pad("a"), game: game, system: system) == .alreadyAssigned(slot: 1))
    }

    @Test func aPressWithNoButtonIsRefused() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(button: [], for: pad("a"), game: game, system: system) == .refused(.noButtonPressed))
        #expect(assignment.controller(in: 1, game: game, system: system) == nil)
    }

    @Test func aPressFillsTheSlotLeftFreeByAReleasedPad() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("b"), game: game, system: system)
        assignment.release(slot: 1, game: game, system: system)
        // The lowest free slot wins, which is the one that was just freed.
        #expect(assignment.claim(button: .east, for: pad("c"), game: game, system: system) == .claimed(slot: 1))
    }

    @Test func aPressSkipsASlotWaitingForAnotherPad() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))
        // Slot 1 is still waiting for its pad, so the press goes to the next free slot.
        #expect(assignment.claim(button: .south, for: pad("b"), game: game, system: system) == .claimed(slot: 2))
        #expect(assignment.disconnectedSlots(game: game, system: system) == [1])
        #expect(assignment.controller(in: 1, game: game, system: system) == pad("a"))
    }

    @Test func aPressInAFullGameFindsNoSlot() {
        let assignment = PlayerAssignment()
        for number in 1...8 {
            assignment.claim(slot: number, for: pad("pad\(number)"), game: game, system: system)
        }
        #expect(assignment.claim(button: .west, for: pad("nine"), game: game, system: system) == .noFreeSlot)
        // The pads already in the game keep their slots.
        #expect(assignment.controller(in: 8, game: game, system: system) == pad("pad8"))
    }

    // MARK: - Games and systems

    @Test func twoGamesKeepTheirOwnSlots() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(slot: 1, for: pad("a"), game: game, system: system) == .claimed(slot: 1))
        #expect(assignment.claim(slot: 1, for: pad("b"), game: otherGame, system: system) == .claimed(slot: 1))
        #expect(assignment.controller(in: 1, game: game, system: system) == pad("a"))
        #expect(assignment.controller(in: 1, game: otherGame, system: system) == pad("b"))
    }

    @Test func twoSystemsKeepTheirOwnSlots() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(slot: 1, for: pad("a"), game: game, system: system) == .claimed(slot: 1))
        #expect(assignment.claim(slot: 1, for: pad("b"), game: game, system: otherSystem) == .claimed(slot: 1))
        #expect(assignment.controller(in: 1, game: game, system: system) == pad("a"))
        #expect(assignment.controller(in: 1, game: game, system: otherSystem) == pad("b"))
    }

    @Test func onePadCanBeADifferentPlayerInEachGame() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("a"), game: otherGame, system: system)
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == 1)
        #expect(assignment.slot(for: pad("a"), game: otherGame, system: system) == 2)
    }

    @Test func aPressInAnotherGameTakesASlotInThatGame() {
        let assignment = PlayerAssignment()
        #expect(assignment.claim(button: .south, for: pad("a"), game: game, system: system) == .claimed(slot: 1))
        // The same pad pressing in another game is a new player there.
        #expect(assignment.claim(button: .south, for: pad("a"), game: otherGame, system: system) == .claimed(slot: 1))
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == 1)
        #expect(assignment.slot(for: pad("a"), game: otherGame, system: system) == 1)
    }

    @Test func claimingInAGameWithNoPriorAssignment() {
        let assignment = PlayerAssignment()
        // A game nobody has played yet has eight free slots and no holder of them.
        let slots = assignment.slots(game: game, system: system)
        #expect(slots.count == 8)
        #expect(slots.allSatisfy { $0.isFree })
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == nil)

        #expect(assignment.claim(slot: 4, for: pad("a"), game: game, system: system) == .claimed(slot: 4))
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == 4)
        // A pad that has not claimed anywhere holds no slot in a game it has not touched.
        #expect(assignment.slot(for: pad("a"), game: otherGame, system: system) == nil)
    }

    // MARK: - Releasing

    @Test func releasingASlotFreesItForTheNextPad() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 2, for: pad("a"), game: game, system: system)
        assignment.release(slot: 2, game: game, system: system)
        #expect(assignment.isSlotAvailable(2, game: game, system: system))
        #expect(assignment.controller(in: 2, game: game, system: system) == nil)
        #expect(assignment.claim(slot: 2, for: pad("b"), game: game, system: system) == .claimed(slot: 2))
    }

    @Test func releasingByControllerFreesTheSlotItHeld() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 5, for: pad("a"), game: game, system: system)
        #expect(assignment.release(controller: pad("a"), game: game, system: system) == 5)
        #expect(assignment.isSlotAvailable(5, game: game, system: system))
        // A pad holding nothing has no slot to release.
        #expect(assignment.release(controller: pad("a"), game: game, system: system) == nil)
    }

    @Test func releasingByControllerFreesEverySlotItHeld() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 4, for: pad("a"), game: game, system: system)
        // The pad is known by the lowest slot it holds, and goes away from all of them.
        #expect(assignment.release(controller: pad("a"), game: game, system: system) == 1)
        #expect(assignment.slot(for: pad("a"), game: game, system: system) == nil)
        #expect(assignment.isSlotAvailable(1, game: game, system: system))
        #expect(assignment.isSlotAvailable(4, game: game, system: system))
    }

    @Test func aPressByAPadThatHoldsTwoSlotsReportsTheLowerOne() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 4, for: pad("a"), game: game, system: system)
        #expect(assignment.claim(button: .south, for: pad("a"), game: game, system: system) == .alreadyAssigned(slot: 1))
    }

    @Test func releasingByControllerLeavesTheOtherPadsSlotsAlone() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 5, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 6, for: pad("b"), game: game, system: system)
        #expect(assignment.release(controller: pad("a"), game: game, system: system) == 5)
        // Only the slot the pad held is freed.
        #expect(assignment.isSlotAvailable(5, game: game, system: system))
        #expect(!assignment.isSlotAvailable(6, game: game, system: system))
        #expect(assignment.controller(in: 6, game: game, system: system) == pad("b"))
    }

    @Test func releasingInOneGameLeavesTheOtherAlone() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 1, for: pad("a"), game: otherGame, system: system)
        assignment.release(slot: 1, game: game, system: system)
        #expect(assignment.isSlotAvailable(1, game: game, system: system))
        #expect(!assignment.isSlotAvailable(1, game: otherGame, system: system))
    }

    @Test func releasingInAGameNobodyHasPlayedIsHarmless() {
        let assignment = PlayerAssignment()
        // The pad holds nothing there, so there is nothing to release.
        #expect(assignment.release(controller: pad("a"), game: game, system: system) == nil)
        // Releasing a slot there frees a slot that was already free.
        assignment.release(slot: 1, game: game, system: system)
        #expect(assignment.isSlotAvailable(1, game: game, system: system))
        #expect(assignment.slots(game: game, system: system).allSatisfy { $0.isFree })
    }

    // MARK: - Disconnect and reconnect

    @Test func theDisconnectedSlotsAreListed() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("b"), game: game, system: system)

        let changes = assignment.disconnect(controller: pad("a"))
        #expect(changes == [SlotChange(game: game, system: system, slot: 1)])
        // Only the pad that went away is listed.
        #expect(assignment.disconnectedSlots(game: game, system: system) == [1])
        #expect(assignment.slots(game: game, system: system)[0].isAwaitingReconnect)
        #expect(!assignment.slots(game: game, system: system)[1].isAwaitingReconnect)
    }

    @Test func aDisconnectedSlotIsNotFreeAndIsNotHandedToAnotherPad() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))
        // The game is waiting for that player, so the slot is not up for grabs.
        #expect(!assignment.isSlotAvailable(1, game: game, system: system))
        #expect(assignment.claim(slot: 1, for: pad("b"), game: game, system: system) == .refused(.slotHeldByOtherController))
        #expect(assignment.controller(in: 1, game: game, system: system) == pad("a"))
    }

    @Test func theReconnectedPadTakesItsSlotBack() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 2, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))
        let back = assignment.reconnect(controller: pad("a"))
        #expect(back == [SlotChange(game: game, system: system, slot: 2)])
        #expect(assignment.disconnectedSlots(game: game, system: system).isEmpty)
        #expect(assignment.controller(in: 2, game: game, system: system) == pad("a"))
        #expect(assignment.slots(game: game, system: system)[1].isAwaitingReconnect == false)
    }

    @Test func aReconnectedPadCanAlsoClaimItsSlotAgain() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 2, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))
        // The press that comes back proves the pad is there, so the slot comes back to life.
        #expect(assignment.claim(button: .south, for: pad("a"), game: game, system: system) == .alreadyAssigned(slot: 2))
        #expect(assignment.disconnectedSlots(game: game, system: system).isEmpty)
        #expect(assignment.controller(in: 2, game: game, system: system) == pad("a"))
    }

    @Test func disconnectingTwiceReportsNothingTheSecondTime() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        #expect(assignment.disconnect(controller: pad("a")).count == 1)
        #expect(assignment.disconnect(controller: pad("a")).isEmpty)
        #expect(assignment.disconnectedSlots(game: game, system: system) == [1])
    }

    @Test func aDisconnectedSlotCanBeFreedForAnotherPad() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("b"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))
        assignment.disconnect(controller: pad("b"))
        #expect(assignment.freeDisconnectedSlots(game: game, system: system) == [1, 2])
        #expect(assignment.isSlotAvailable(1, game: game, system: system))
        #expect(assignment.claim(slot: 1, for: pad("c"), game: game, system: system) == .claimed(slot: 1))
    }

    @Test func aFreedSlotGoesToTheNextPress() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))
        assignment.freeDisconnectedSlots(game: game, system: system)
        // With the waiting slot given up, the freed slot is the lowest free one.
        #expect(assignment.claim(button: .north, for: pad("b"), game: game, system: system) == .claimed(slot: 1))
        #expect(assignment.disconnectedSlots(game: game, system: system).isEmpty)
    }

    @Test func aPadHoldingTwoSlotsLosesBothWhenItGoesAway() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 4, for: pad("a"), game: game, system: system)
        let changes = assignment.disconnect(controller: pad("a"))
        #expect(changes.count == 2)
        #expect(changes.contains(SlotChange(game: game, system: system, slot: 1)))
        #expect(changes.contains(SlotChange(game: game, system: system, slot: 4)))
        #expect(assignment.disconnectedSlots(game: game, system: system) == [1, 4])
    }

    @Test func aDisconnectIsReportedForEveryGameThePadWasIn() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 3, for: pad("a"), game: otherGame, system: system)
        let changes = assignment.disconnect(controller: pad("a"))
        #expect(changes.count == 2)
        #expect(changes.contains(SlotChange(game: game, system: system, slot: 1)))
        #expect(changes.contains(SlotChange(game: otherGame, system: system, slot: 3)))
        // Each game lists its own waiting slot.
        #expect(assignment.disconnectedSlots(game: game, system: system) == [1])
        #expect(assignment.disconnectedSlots(game: otherGame, system: system) == [3])
    }

    @Test func reconnectingAPadThatNeverWentAwayDoesNothing() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        #expect(assignment.reconnect(controller: pad("a")).isEmpty)
        #expect(assignment.disconnectedSlots(game: game, system: system).isEmpty)
        #expect(assignment.controller(in: 1, game: game, system: system) == pad("a"))
    }

    // MARK: - The active game

    @Test func theActiveGameDecidesWhichTableTheContextFreeCallsUse() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        #expect(assignment.activeContext == nil)
        // With no active game the call can only say whether the number names a slot.
        #expect(assignment.isSlotAvailable(1))
        #expect(!assignment.isSlotAvailable(0))

        assignment.activate(game: game, system: system)
        #expect(assignment.activeContext == PlayerAssignment.Context(game: game, system: system))
        #expect(!assignment.isSlotAvailable(1))
        #expect(assignment.slots().count == 8)
        #expect(assignment.slots()[0].controller == pad("a"))
    }

    @Test func switchingTheActiveGameSwitchesTheTable() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 1, for: pad("b"), game: otherGame, system: system)

        assignment.activate(game: game, system: system)
        #expect(assignment.slots()[0].controller == pad("a"))
        assignment.activate(game: otherGame, system: system)
        #expect(assignment.slots()[0].controller == pad("b"))
    }

    @Test func theActiveGameIsTheOneWhoseDisconnectedSlotsAreListed() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("a"), game: otherGame, system: system)
        assignment.disconnect(controller: pad("a"))
        #expect(assignment.disconnectedSlots().isEmpty)

        assignment.activate(game: game, system: system)
        #expect(assignment.disconnectedSlots() == [1])
    }

    @Test func theActiveGamesDisconnectedSlotsAreTheOnesFreed() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("a"), game: otherGame, system: system)
        assignment.disconnect(controller: pad("a"))
        assignment.activate(game: game, system: system)
        // Only the active game's slot is freed, so the other game still waits for its player.
        #expect(assignment.freeDisconnectedSlots() == [1])
        #expect(assignment.isSlotAvailable(1, game: game, system: system))
        #expect(!assignment.isSlotAvailable(2, game: otherGame, system: system))
    }

    @Test func freeingTheDisconnectedSlotsOfAGameWithNoTableDoesNothing() {
        let assignment = PlayerAssignment()
        #expect(assignment.freeDisconnectedSlots(game: game, system: system).isEmpty)
        #expect(assignment.disconnectedSlots(game: game, system: system).isEmpty)
    }

    // MARK: - Persistence

    @Test func theSnapshotRoundTripsThroughJSON() throws {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("b"), game: game, system: system)
        assignment.claim(slot: 1, for: pad("c"), game: otherGame, system: system)

        let data = try JSONEncoder().encode(assignment.snapshot())
        let decoded = try JSONDecoder().decode(PlayerAssignment.Snapshot.self, from: data)
        #expect(decoded == assignment.snapshot())

        let restored = PlayerAssignment(snapshot: decoded)
        #expect(restored.controller(in: 1, game: game, system: system) == pad("a"))
        #expect(restored.controller(in: 2, game: game, system: system) == pad("b"))
        #expect(restored.controller(in: 1, game: otherGame, system: system) == pad("c"))
        #expect(restored.slot(for: pad("c"), game: otherGame, system: system) == 1)
        #expect(restored.snapshot() == assignment.snapshot())
    }

    @Test func theSnapshotKeepsGamesAndSystemsApart() throws {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 1, for: pad("b"), game: game, system: otherSystem)
        assignment.claim(slot: 1, for: pad("c"), game: otherGame, system: system)

        let data = try JSONEncoder().encode(assignment.snapshot())
        let restored = PlayerAssignment(snapshot: try JSONDecoder().decode(PlayerAssignment.Snapshot.self, from: data))
        #expect(restored.controller(in: 1, game: game, system: system) == pad("a"))
        #expect(restored.controller(in: 1, game: game, system: otherSystem) == pad("b"))
        #expect(restored.controller(in: 1, game: otherGame, system: system) == pad("c"))
    }

    @Test func aDisconnectedSlotSurvivesTheSnapshot() throws {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))

        let data = try JSONEncoder().encode(assignment.snapshot())
        let decoded = try JSONDecoder().decode(PlayerAssignment.Snapshot.self, from: data)
        let restored = PlayerAssignment(snapshot: decoded)
        // The game still has to wait for that player after a relaunch.
        #expect(restored.disconnectedSlots(game: game, system: system) == [1])
        #expect(restored.slots(game: game, system: system)[0].isAwaitingReconnect)
    }

    @Test func theSnapshotListsTheGamesInOrder() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: otherGame, system: system)
        assignment.claim(slot: 1, for: pad("b"), game: game, system: otherSystem)
        assignment.claim(slot: 1, for: pad("c"), game: game, system: system)

        let entries = assignment.snapshot().entries
        #expect(entries.count == 3)
        #expect(entries.map(\.game) == [game, game, otherGame])
        #expect(entries.map(\.system) == [system, otherSystem, system])
        // Every entry carries the eight slots of its game.
        #expect(entries.allSatisfy { $0.slots.count == 8 })
    }

    @Test func theSnapshotIsWrittenAsJSONTheAppCanRead() throws {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 2, for: pad("a"), game: game, system: system)
        assignment.disconnect(controller: pad("a"))

        let data = try JSONEncoder().encode(assignment.snapshot())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry["game"] as? String == game)
        #expect(entry["system"] as? String == system)
        let slots = try #require(entry["slots"] as? [[String: Any]])
        #expect(slots.count == 8)
        // The slots are written in order, slot 1 first, so the file can be read back as a table.
        #expect(slots.compactMap { $0["number"] as? Int } == Array(1...8))
        // A slot whose pad has gone away says so, and still names the pad it was waiting for.
        let second = slots[1]
        #expect(second["connected"] as? Bool == false)
        #expect(second["controller"] as? [String: Any] != nil)
    }

    @Test func restoringASnapshotReplacesTheTable() {
        let assignment = PlayerAssignment()
        assignment.claim(slot: 1, for: pad("a"), game: game, system: system)
        assignment.claim(slot: 2, for: pad("b"), game: otherGame, system: system)

        let saved = assignment.snapshot()
        assignment.release(slot: 1, game: game, system: system)
        assignment.release(slot: 2, game: otherGame, system: system)
        #expect(assignment.isSlotAvailable(1, game: game, system: system))

        assignment.restore(saved)
        #expect(assignment.controller(in: 1, game: game, system: system) == pad("a"))
        #expect(assignment.controller(in: 2, game: otherGame, system: system) == pad("b"))
    }
}
