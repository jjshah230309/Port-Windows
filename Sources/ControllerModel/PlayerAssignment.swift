import EmulatorKit
import Synchronization

/// The player slots of a running game: eight of them, each free, held by a controller, or held by
/// a controller that has gone away.
///
/// A class rather than a struct: the table is written by the controllers pane and read by the
/// emulation thread, and neither should have to copy it. The mutex is what makes sharing it safe.
public final class PlayerAssignment: Sendable {
    /// How many player slots a game offers.
    public static let slotCount = 8
    /// The slot numbers a game offers, 1 to 8, as the "Player N" in the UI shows them.
    public static let slotRange = 1...8

    // MARK: - Types

    /// A game and the system it runs on. Assignments are kept per pair, so one controller can be
    /// player 1 in one game and player 2 in another.
    public struct Context: Hashable, Codable, Sendable {
        public var game: String
        public var system: String

        public init(game: String, system: String) {
            self.game = game
            self.system = system
        }
    }

    /// One player slot: its number, the controller holding it, and whether that controller is
    /// still attached. A slot with no controller is free; a slot whose controller has gone away
    /// is waiting to be reclaimed.
    public struct ControllerSlot: Equatable, Codable, Sendable {
        public var number: Int
        /// The controller holding the slot, if any.
        public var controller: ControllerID?
        /// False once the holder has gone away. Meaningless for a free slot.
        public var connected: Bool

        public init(number: Int, controller: ControllerID? = nil, connected: Bool = true) {
            self.number = number
            self.controller = controller
            self.connected = connected
        }

        /// True when no controller holds the slot.
        public var isFree: Bool { controller == nil }
        /// True when the holder has gone away and the game is waiting for it.
        public var isAwaitingReconnect: Bool { controller != nil && !connected }
    }

    /// What a claim did.
    public enum ClaimResult: Equatable, Sendable {
        /// The controller holds this slot.
        case claimed(slot: Int)
        /// The controller already held this slot and is still connected, so nothing changed.
        case alreadyAssigned(slot: Int)
        /// The claim was refused.
        case refused(Refusal)
        /// Every slot in this game is taken.
        case noFreeSlot
    }

    /// Why a claim was refused.
    public enum Refusal: Equatable, Sendable {
        /// The slot number is outside 1 to 8.
        case slotOutOfRange
        /// Another controller holds the slot.
        case slotHeldByOtherController
        /// No button was pressed, so there was nothing to claim with.
        case noButtonPressed
    }

    /// A slot that changed hands, with the game it belongs to.
    public struct SlotChange: Equatable, Sendable {
        public var game: String
        public var system: String
        public var slot: Int

        public init(game: String, system: String, slot: Int) {
            self.game = game
            self.system = system
            self.slot = slot
        }
    }

    /// The saved table: one entry per game and system, each with its slots. Codable, so the app
    /// can write it to disk and read it back.
    public struct Snapshot: Equatable, Codable, Sendable {
        /// One game's slots.
        public struct Entry: Equatable, Codable, Sendable {
            public var game: String
            public var system: String
            public var slots: [ControllerSlot]

            public init(game: String, system: String, slots: [ControllerSlot]) {
                self.game = game
                self.system = system
                self.slots = slots
            }
        }

        public var entries: [Entry]

        public init(entries: [Entry] = []) {
            self.entries = entries
        }
    }

    // MARK: - State

    /// What one slot holds.
    private struct SlotRecord: Equatable, Sendable {
        var controller: ControllerID?
        /// False once the controller has gone away; the game waits for it to come back.
        var connected: Bool
    }

    /// The mutable state, behind the mutex.
    private struct State: Sendable {
        /// One table per game and system, each with exactly `slotCount` slots.
        var tables: [Context: [SlotRecord]] = [:]
        /// The game the context-free methods work on.
        var active: Context?
    }

    private let state = Mutex(State())

    public init() {}

    /// Restores a saved table.
    public init(snapshot: Snapshot) {
        state.withLock { $0.tables = PlayerAssignment.tables(from: snapshot) }
    }

    // MARK: - Helpers

    private static func emptyTable() -> [SlotRecord] {
        Array(repeating: SlotRecord(controller: nil, connected: true), count: slotCount)
    }

    /// The public view of a table, slot 1 first.
    private static func view(_ table: [SlotRecord]) -> [ControllerSlot] {
        table.enumerated().map { index, record in
            ControllerSlot(number: index + 1, controller: record.controller, connected: record.connected)
        }
    }

    private static func tables(from snapshot: Snapshot) -> [Context: [SlotRecord]] {
        var tables: [Context: [SlotRecord]] = [:]
        for entry in snapshot.entries {
            var table = emptyTable()
            for slot in entry.slots where slotRange.contains(slot.number) {
                table[slot.number - 1] = SlotRecord(controller: slot.controller, connected: slot.connected)
            }
            tables[Context(game: entry.game, system: entry.system)] = table
        }
        return tables
    }
}

// MARK: - Active game

extension PlayerAssignment {
    /// The game the context-free methods work on.
    public var activeContext: Context? { state.withLock { $0.active } }

    /// Points the context-free methods at a game, giving it a table if it has none.
    public func activate(game: String, system: String) {
        let context = Context(game: game, system: system)
        state.withLock { inner in
            inner.active = context
            if inner.tables[context] == nil { inner.tables[context] = PlayerAssignment.emptyTable() }
        }
    }
}

// MARK: - Claiming

extension PlayerAssignment {
    /// The press-a-button rule: a controller that presses a button in a game where it holds no
    /// slot takes the lowest free one. The press that arrives first gets it, and a later press
    /// finds the next free slot rather than taking one that is held. A controller that already
    /// holds a slot ignores the press, so the game still sees the button, and a press in a full
    /// game is refused.
    @discardableResult
    public func claim(button: PadButtons, for controller: ControllerID, game: String, system: String) -> ClaimResult {
        guard !button.isEmpty else { return .refused(.noButtonPressed) }
        let context = Context(game: game, system: system)
        return state.withLock { inner in
            let table = inner.tables[context] ?? PlayerAssignment.emptyTable()
            if let index = table.firstIndex(where: { $0.controller == controller }) {
                // A press proves the pad is there, so a slot waiting for it comes back to life.
                var updated = table
                updated[index].connected = true
                inner.tables[context] = updated
                return .alreadyAssigned(slot: index + 1)
            }
            guard let index = table.firstIndex(where: { $0.controller == nil }) else { return .noFreeSlot }
            var updated = table
            updated[index].controller = controller
            updated[index].connected = true
            inner.tables[context] = updated
            return .claimed(slot: index + 1)
        }
    }

    /// Claims a named slot. The slot must be in range and free: a slot another controller holds
    /// is refused, whether that controller is still attached or waiting to come back. A slot the
    /// same controller already holds is left alone, unless the controller had gone away, in which
    /// case it takes the slot back.
    @discardableResult
    public func claim(slot: Int, for controller: ControllerID, game: String, system: String) -> ClaimResult {
        let context = Context(game: game, system: system)
        return state.withLock { inner in
            guard PlayerAssignment.slotRange.contains(slot) else { return .refused(.slotOutOfRange) }
            let table = inner.tables[context] ?? PlayerAssignment.emptyTable()
            if let holder = table[slot - 1].controller {
                guard holder == controller else { return .refused(.slotHeldByOtherController) }
                guard table[slot - 1].connected else {
                    var updated = table
                    updated[slot - 1].connected = true
                    inner.tables[context] = updated
                    return .claimed(slot: slot)
                }
                return .alreadyAssigned(slot: slot)
            }
            var updated = table
            updated[slot - 1].controller = controller
            updated[slot - 1].connected = true
            inner.tables[context] = updated
            return .claimed(slot: slot)
        }
    }
}

// MARK: - Releasing

extension PlayerAssignment {
    /// Frees a slot, whoever holds it.
    public func release(slot: Int, game: String, system: String) {
        let context = Context(game: game, system: system)
        state.withLock { inner in
            guard PlayerAssignment.slotRange.contains(slot) else { return }
            var table = inner.tables[context] ?? PlayerAssignment.emptyTable()
            table[slot - 1] = SlotRecord(controller: nil, connected: true)
            inner.tables[context] = table
        }
    }

    /// Frees the slot a controller holds in a game. Returns the slot it held, if any.
    @discardableResult
    public func release(controller: ControllerID, game: String, system: String) -> Int? {
        let context = Context(game: game, system: system)
        return state.withLock { inner -> Int? in
            guard let table = inner.tables[context] else { return nil }
            guard let index = table.firstIndex(where: { $0.controller == controller }) else { return nil }
            var updated = table
            updated[index] = SlotRecord(controller: nil, connected: true)
            inner.tables[context] = updated
            return index + 1
        }
    }
}

// MARK: - Inspection

extension PlayerAssignment {
    /// Whether a slot is free in the active game. With no active game, whether the number names
    /// a slot at all.
    public func isSlotAvailable(_ slot: Int) -> Bool {
        guard let context = activeContext else { return PlayerAssignment.slotRange.contains(slot) }
        return isSlotAvailable(slot, game: context.game, system: context.system)
    }

    /// Whether a slot is free in a game: in range, and not held by a controller. A slot whose
    /// controller has gone away is not free, because the game is waiting for that player.
    public func isSlotAvailable(_ slot: Int, game: String, system: String) -> Bool {
        guard PlayerAssignment.slotRange.contains(slot) else { return false }
        let context = Context(game: game, system: system)
        return state.withLock { inner in
            guard let table = inner.tables[context] else { return true }
            return table[slot - 1].controller == nil
        }
    }

    /// The slot a controller holds in a game.
    public func slot(for controller: ControllerID, game: String, system: String) -> Int? {
        let context = Context(game: game, system: system)
        return state.withLock { inner -> Int? in
            guard let table = inner.tables[context] else { return nil }
            guard let index = table.firstIndex(where: { $0.controller == controller }) else { return nil }
            return index + 1
        }
    }

    /// The controller holding a slot in a game.
    public func controller(in slot: Int, game: String, system: String) -> ControllerID? {
        guard PlayerAssignment.slotRange.contains(slot) else { return nil }
        let context = Context(game: game, system: system)
        return state.withLock { inner in
            guard let table = inner.tables[context] else { return nil }
            return table[slot - 1].controller
        }
    }

    /// Every slot in a game, in order.
    public func slots(game: String, system: String) -> [ControllerSlot] {
        let context = Context(game: game, system: system)
        return state.withLock { inner in
            PlayerAssignment.view(inner.tables[context] ?? PlayerAssignment.emptyTable())
        }
    }

    /// Every slot in the active game.
    public func slots() -> [ControllerSlot] {
        guard let context = activeContext else {
            return PlayerAssignment.view(PlayerAssignment.emptyTable())
        }
        return slots(game: context.game, system: context.system)
    }
}

// MARK: - Disconnect and reconnect

extension PlayerAssignment {
    /// Records that a controller has gone away. Its slots keep their numbers, so the game can
    /// pause and show "Reconnect Player N", and the same controller gets them back when it
    /// returns. Returns the slots that lost their controller, in every game.
    @discardableResult
    public func disconnect(controller: ControllerID) -> [SlotChange] {
        state.withLock { inner in
            var changes: [SlotChange] = []
            let tables = inner.tables
            var updated = tables
            for (context, var table) in tables {
                var changed = false
                for index in table.indices {
                    guard table[index].controller == controller, table[index].connected else { continue }
                    table[index].connected = false
                    changed = true
                    changes.append(SlotChange(game: context.game, system: context.system, slot: index + 1))
                }
                if changed { updated[context] = table }
            }
            inner.tables = updated
            return changes
        }
    }

    /// Records that a controller is back. The slots it held before it went away come back to
    /// life, so the game resumes with the same players in the same slots.
    @discardableResult
    public func reconnect(controller: ControllerID) -> [SlotChange] {
        state.withLock { inner in
            var changes: [SlotChange] = []
            let tables = inner.tables
            var updated = tables
            for (context, var table) in tables {
                var changed = false
                for index in table.indices {
                    guard table[index].controller == controller, !table[index].connected else { continue }
                    table[index].connected = true
                    changed = true
                    changes.append(SlotChange(game: context.game, system: context.system, slot: index + 1))
                }
                if changed { updated[context] = table }
            }
            inner.tables = updated
            return changes
        }
    }

    /// The slots in a game whose controller has gone away. The game pauses on these with
    /// "Reconnect Player N".
    public func disconnectedSlots(game: String, system: String) -> [Int] {
        let context = Context(game: game, system: system)
        return state.withLock { inner in
            guard let table = inner.tables[context] else { return [] }
            return table.enumerated().compactMap { index, record in
                record.controller != nil && !record.connected ? index + 1 : nil
            }
        }
    }

    /// The slots in the active game whose controller has gone away.
    public func disconnectedSlots() -> [Int] {
        guard let context = activeContext else { return [] }
        return disconnectedSlots(game: context.game, system: context.system)
    }

    /// Frees the slots whose controller disconnected, so another controller can take them over.
    /// Returns the slots that were freed.
    @discardableResult
    public func freeDisconnectedSlots(game: String, system: String) -> [Int] {
        let context = Context(game: game, system: system)
        return state.withLock { inner in
            guard var table = inner.tables[context] else { return [] }
            var freed: [Int] = []
            for index in table.indices where table[index].controller != nil && !table[index].connected {
                table[index] = SlotRecord(controller: nil, connected: true)
                freed.append(index + 1)
            }
            guard !freed.isEmpty else { return [] }
            inner.tables[context] = table
            return freed
        }
    }

    /// Frees the slots in the active game whose controller disconnected.
    @discardableResult
    public func freeDisconnectedSlots() -> [Int] {
        guard let context = activeContext else { return [] }
        return freeDisconnectedSlots(game: context.game, system: context.system)
    }
}

// MARK: - Persistence

extension PlayerAssignment {
    /// The saved form of the table, for writing to disk.
    public func snapshot() -> Snapshot {
        state.withLock { inner in
            let entries = inner.tables
                .map { context, table in
                    Snapshot.Entry(game: context.game, system: context.system, slots: PlayerAssignment.view(table))
                }
                .sorted { ($0.game, $0.system) < ($1.game, $1.system) }
            return Snapshot(entries: entries)
        }
    }

    /// Replaces the table with a saved one.
    public func restore(_ snapshot: Snapshot) {
        state.withLock { $0.tables = PlayerAssignment.tables(from: snapshot) }
    }
}
