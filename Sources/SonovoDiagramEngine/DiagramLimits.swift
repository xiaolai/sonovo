public enum DiagramLimits {
    public static let maxGraphvizSourceCharacters = 32_768
    public static let maxMarkmapSourceCharacters = 32_768
    public static let maxMermaidEdges = 500
    public static let maxMermaidRenderCacheEntries = 128
    public static let maxMermaidSVGBytes = 4 * 1024 * 1024
    public static let maxMermaidSourceCharacters = 32_768
    public static let maxSVGFenceBytes = 2 * 1024 * 1024
    public static let mermaidRenderTimeoutSeconds: Double = 10
    public static let svgSanitizeTimeoutSeconds: Double = 2
}
