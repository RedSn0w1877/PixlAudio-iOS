// The one scorer (docs/brain-spec.md, 5.7, 5.8). In stages 1 and 2 the weights are the hand-set prior `M0`,
// unchanged: a fixed formula. The learner of 5.9 arrives in stage 3. A transliteration of the Android `:brain`
// module's `Ranker.kt`.

/// The scorer.
public enum Ranker {
    public static let d = 51

    /// pi / 8, as the spec writes it.
    static let probit: Double = 0.3927

    /// Prior weights. Index 0 (bias) is `logit(p0)`, filled in by `weights`.
    static let m0Table: [Double] = [
        0.0, // 0 bias
        1.2, // 1 track_aff
        1.0, // 2 artist_aff
        0.4, // 3 artist_aff_recent
        0.8, // 4 tag_aff
        1.0, // 5 island_sim
        0.3, // 6 island_weight
        0.2, // 7 decade_aff
        0.8, // 8 liked
        0.4, // 9 in_playlists
        0.5, // 10 actr
        -0.3, // 11 actr_sq
        -1.5, -0.6, -0.1, 0.1, 0.2, // 12-16 since_last
        -0.3, // 17 unheard_track
        -0.4, // 18 unheard_artist
        -0.5, // 19 novelty_dist
        0.0, // 20 pop
        0.3, // 21 pop_x_mainstream
        0.8, // 22 sess_pos_sim
        -1.0, // 23 sess_neg_sim
        -1.0, // 24 sess_tag_pen
        0.4, // 25 prev_completed
        -0.4, // 26 skip_run
        -0.3, // 27 tempo_jump
        -0.1, // 28 loud_jump
        0.5, // 29 ctx_lift
        0.0, // 30 weekend
        0.0, 0.0, 0.0, 0.0, // 31-34 route
        0.0, // 35 route_x_energy
        0.4, // 36 arm_aff
        0.5, // 37 retrieval
        0.3, // 38 radio_rank
        0.2, // 39 fresh
        -0.2, // 40 duration_dev
        0.0, // 41 explicit_mismatch
        0.0, // 42 passive_ctx
        0.0, // 43 position
        0.0, 0.0, 0.0, 0.0, // 44-47 surface family
        0.0, 0.0, 0.0, // 48-50 origin
    ]

    /// Prior standard deviations.
    static let sd0Table: [Double] = [
        0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.3, 0.5, 0.5, 0.5, 0.3,
        0.5, 0.5, 0.5, 0.5, 0.5,
        0.5, 0.5, 0.5, 0.3, 0.3, 0.5, 0.5, 0.5, 0.3, 0.3, 0.3, 0.3, 0.5, 0.2,
        0.2, 0.2, 0.2, 0.2,
        0.2, 0.3, 0.5, 0.3, 0.3, 0.3, 0.3, 0.2, 0.2,
        0.3, 0.3, 0.3, 0.3,
        0.5, 0.5, 0.5,
    ]

    /// Prior precisions `q_i = 1 / SD0_i^2`.
    static let q0Table: [Double] = sd0Table.map { 1.0 / ($0 * $0) }

    public static func m0(_ index: Int) -> Double { m0Table[index] }

    public static func sd0(_ index: Int) -> Double { sd0Table[index] }

    /// The weight vector for a listener whose base completion rate is `p0`.
    public static func weights(p0: Double) -> [Double] {
        var w = m0Table
        w[0] = BrainMath.logit(p0)
        return w
    }

    /// `z = sum_i w_i * x_i`, by index.
    public static func z(_ w: [Double], _ x: [Double]) -> Double {
        var z = 0.0
        for i in 0..<d { z += w[i] * x[i] }
        return z
    }

    /// `p = sigmoid(z / sqrt(1 + 0.3927 * s))`, `s = sum_i x_i^2 / q_i`.
    public static func p(_ z: Double, _ x: [Double]) -> Double {
        var s = 0.0
        for i in 0..<d { s += x[i] * x[i] / q0Table[i] }
        return BrainMath.sigmoid(z / BrainMath.sqrt(1.0 + probit * s))
    }
}
