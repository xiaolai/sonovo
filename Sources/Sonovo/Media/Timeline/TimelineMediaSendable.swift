import AVFoundation

// The composition, mix, and video composition are built once on the main
// actor and never mutated afterwards. Preview reads them on the main actor;
// peak measurement reads the same immutable graph on a worker. Marking the
// AVFoundation values Sendable is the explicit bridge for that handoff, not a
// claim that AVFoundation mutation is thread-safe.
extension AVMutableComposition: @unchecked @retroactive Sendable {}
extension AVAudioMix: @unchecked @retroactive Sendable {}
