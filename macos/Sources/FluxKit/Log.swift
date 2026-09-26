import os

/// Loggers for `log stream --predicate 'subsystem == "org.omarchy.flux"'`.
public enum FluxLog {
    public static let net = Logger(subsystem: "org.omarchy.flux", category: "net")
    public static let core = Logger(subsystem: "org.omarchy.flux", category: "core")
    public static let plugin = Logger(subsystem: "org.omarchy.flux", category: "plugin")
}
