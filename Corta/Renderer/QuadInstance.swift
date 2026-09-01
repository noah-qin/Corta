import simd

/// One instanced quad — a solid rect, or (with a non-zero `uvRect`) a glyph
/// sampled from the atlas texture.
///
/// The field order and types here must match `QuadInstance` in
/// `Shaders.metal` exactly: `SIMD2<Float>` and `SIMD4<Float>` have the same
/// size and alignment on arm64 as Metal's `float2`/`float4`, so the two
/// structs line up byte-for-byte with no packing directives needed — but
/// only as long as a field added on one side is mirrored on the other.
nonisolated struct QuadInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var uvRect: SIMD4<Float> = .zero
}

/// Per-draw-call uniforms. Mirrors `QuadUniforms` in `Shaders.metal`.
nonisolated struct QuadUniforms {
    var rectOrigin: SIMD2<Float>
    var rectSize: SIMD2<Float>
    var drawableSize: SIMD2<Float>
}
