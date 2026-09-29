/// The SF Symbol of a device type, in the app and the share extension.
enum DeviceSymbol {
    static func name(_ type: String) -> String {
        switch type {
        case "laptop": return "laptopcomputer"
        case "desktop": return "desktopcomputer"
        case "tablet": return "ipad"
        case "tv": return "tv"
        default: return "iphone"
        }
    }
}
