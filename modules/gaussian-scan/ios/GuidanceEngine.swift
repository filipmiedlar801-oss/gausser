import Foundation
import simd

struct GuidanceInput {
  var trackingState: String
  var trackingReason: String
  var speed: Float
  var angularSpeed: Float
  var lux: Float
  var medianDepth: Float
  var sharpness01: Float
  var motionBlurRisk: Float
  /// Camera forward · worldUp — positive when looking toward the ceiling.
  var lookUp: Float
  var stats: CoverageStats?
  var scanDuration: TimeInterval
  var waypointDistance: Float?
  var holeCount: Int
}

struct GuidanceHint {
  var code: String
  var params: [String: Any] = [:]
}

/// Rule machine producing a single "current" hint with hysteresis plus one-shot events.
/// Codes are translated to Polish strings on the JS side.
final class GuidanceEngine {
  private var currentCode = ""
  private var currentSince: TimeInterval = 0
  private var lastEmit: TimeInterval = 0
  private var cooldowns: [String: TimeInterval] = [:]
  private var previousHoleCount: Int = -1
  private var waypointWasActive = false
  private var lookUpAccumulated: TimeInterval = 0
  private var lastTick: TimeInterval = 0
  private var ceilingPromptSatisfied = false
  private var floorPromptSatisfied = false

  private let minHintDuration: TimeInterval = 2.0
  private let repeatInterval: TimeInterval = 6.0

  /// Returns hints to emit (0..2: possibly a one-shot event + the current hint).
  func tick(_ input: GuidanceInput, now: TimeInterval) -> [GuidanceHint] {
    var events: [GuidanceHint] = []

    let dt: TimeInterval = lastTick > 0 ? min(0.5, now - lastTick) : 0
    lastTick = now
    if input.lookUp > 0.40 {
      lookUpAccumulated += dt
      if lookUpAccumulated > 2.5 {
        ceilingPromptSatisfied = true
      }
    }
    if input.lookUp < -0.35 {
      floorPromptSatisfied = true
    }

    // One-shot: waypoint reached
    if let wd = input.waypointDistance {
      waypointWasActive = true
      if wd < 1.0 && cooldownPassed("waypoint_reached", now: now, interval: 8) {
        events.append(GuidanceHint(code: "waypoint_reached"))
      }
    } else {
      waypointWasActive = false
    }

    // One-shot: an area got completed (hole count dropped)
    if previousHoleCount >= 0 && input.holeCount < previousHoleCount && input.scanDuration > 15 {
      if cooldownPassed("area_completed", now: now, interval: 10) {
        events.append(GuidanceHint(code: "area_completed"))
      }
    }
    previousHoleCount = input.holeCount

    let desired = evaluate(input)

    let elapsed = now - currentSince
    let priorityJump = priority(desired.code) < priority(currentCode)
    if desired.code != currentCode {
      if currentCode.isEmpty || elapsed >= minHintDuration || priorityJump {
        currentCode = desired.code
        currentSince = now
        lastEmit = now
        events.append(desired)
      }
    } else if now - lastEmit >= repeatInterval {
      lastEmit = now
      events.append(desired)
    }
    return events
  }

  private func cooldownPassed(_ code: String, now: TimeInterval, interval: TimeInterval) -> Bool {
    if let last = cooldowns[code], now - last < interval { return false }
    cooldowns[code] = now
    return true
  }

  private func priority(_ code: String) -> Int {
    switch code {
    case "tracking_lost": return 0
    case "tracking_limited", "initializing": return 1
    case "hold_still", "rotate_slower", "slow_down": return 2
    case "too_dark": return 3
    case "too_close", "move_closer": return 4
    case "goto_gap": return 5
    case "show_ceiling", "show_floor": return 6
    case "more_angles": return 7
    case "good": return 9
    default: return 8
    }
  }

  private func evaluate(_ input: GuidanceInput) -> GuidanceHint {
    if input.trackingState == "notAvailable" {
      return GuidanceHint(code: "tracking_lost")
    }
    if input.trackingState == "limited" {
      if input.trackingReason == "initializing" {
        return GuidanceHint(code: "initializing")
      }
      return GuidanceHint(code: "tracking_limited", params: ["reason": input.trackingReason])
    }
    if input.angularSpeed > 32 {
      return GuidanceHint(code: "rotate_slower")
    }
    if input.speed > 0.50 {
      return GuidanceHint(code: "slow_down")
    }
    if input.motionBlurRisk > 0.42 || input.sharpness01 < 0.30 {
      return GuidanceHint(code: "hold_still")
    }
    if input.lux > 0 && input.lux < 220 {
      return GuidanceHint(code: "too_dark")
    }
    if input.medianDepth > 0 {
      // Don't nag "move closer" while looking at the ceiling — rooms are tall.
      let depthLimit: Float = input.lookUp > 0.35 ? 5.0 : 3.5
      if input.medianDepth > depthLimit {
        return GuidanceHint(code: "move_closer")
      }
      if input.medianDepth < 0.35 {
        return GuidanceHint(code: "too_close")
      }
    }
    if let wd = input.waypointDistance {
      return GuidanceHint(code: "goto_gap", params: ["distance": wd])
    }
    if let stats = input.stats, input.scanDuration > 25, stats.wallsGreen > 0.45 {
      // Mark prompts satisfied once coverage is actually there.
      if stats.ceilingSamples > 40 && stats.ceilingGreen >= 0.30 {
        ceilingPromptSatisfied = true
      }
      if stats.floorSamples > 40 && stats.floorGreen >= 0.30 {
        floorPromptSatisfied = true
      }

      // Stuck-fix: never ask for ceiling forever when samples==0 (old ceilingGreen
      // stayed 0 and the hint never cleared). Only prompt when useful.
      if !ceilingPromptSatisfied {
        let needsCeilingCoverage = stats.ceilingSamples > 40 && stats.ceilingGreen < 0.30
        let neverLookedUp = stats.ceilingSamples < 25 && input.lookUp < 0.35
        if needsCeilingCoverage || neverLookedUp {
          // If the user is already looking up, let them scan instead of nagging.
          if input.lookUp < 0.45 {
            return GuidanceHint(code: "show_ceiling")
          }
        }
      }

      if !floorPromptSatisfied {
        let needsFloorCoverage = stats.floorSamples > 40 && stats.floorGreen < 0.30
        let neverLookedDown = stats.floorSamples < 25 && input.lookUp > -0.25
        if (needsFloorCoverage || neverLookedDown) && input.lookUp > -0.40 {
          return GuidanceHint(code: "show_floor")
        }
      }
    }
    // Seen once from one direction — walk around for multi-view (Gaussian needs angles).
    if let stats = input.stats, input.scanDuration > 35,
       stats.yellow > 0.28, stats.red < 0.22, stats.green < 0.55 {
      return GuidanceHint(code: "more_angles")
    }
    return GuidanceHint(code: "good")
  }

  func reset() {
    currentCode = ""
    currentSince = 0
    lastEmit = 0
    lastTick = 0
    cooldowns.removeAll()
    previousHoleCount = -1
    lookUpAccumulated = 0
    ceilingPromptSatisfied = false
    floorPromptSatisfied = false
  }
}
