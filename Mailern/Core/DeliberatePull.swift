import Foundation

struct DeliberatePull {
    static let threshold: Double = 120
    private(set) var eligible = false
    private(set) var distance: Double = 0
    var armed: Bool { eligible && distance >= Self.threshold }

    mutating func begin(offset: Double, stationary: Bool) {
        eligible = stationary && abs(offset) <= 1
        distance = 0
    }

    mutating func move(distance: Double) {
        self.distance = eligible ? max(0, distance) : 0
    }

    mutating func end(distance: Double) -> Bool {
        move(distance: distance)
        let activate = armed
        self = Self()
        return activate
    }
}
