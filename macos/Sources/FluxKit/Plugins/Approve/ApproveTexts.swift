import LocalAuthentication

/// The texts of approvals, with the name of the device and of its biometry.
/// A Mac approves only with Touch ID. An iPhone has Face ID or Touch ID.
public struct ApproveTexts: Sendable {
    typealias Platform = FluxPlatform

    let platform: Platform
    /// "Touch ID", "Face ID", "Optic ID", or the passcode or password.
    public let biometry: String
    /// The part of the body that the biometry reads, or nil without biometry.
    private let trait: String?

    init(platform: Platform, type: LABiometryType) {
        self.platform = platform
        biometry = Self.biometry(type, platform: platform)
        trait = switch type {
        case .faceID: "face"
        case .opticID: "eye"
        case .touchID: "fingerprint"
        default: nil
        }
    }

    /// The texts of this device. It asks LocalAuthentication for the
    /// biometry of the iPhone.
    public static var current: ApproveTexts {
        #if os(macOS)
        ApproveTexts(platform: .mac, type: .touchID)
        #else
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ApproveTexts(platform: .phone, type: context.biometryType)
        #endif
    }

    /// The name of the biometry, or of the secret without one.
    static func biometry(_ type: LABiometryType, platform: Platform) -> String {
        switch type {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: platform == .mac ? "your password" : "your passcode"
        }
    }

    public var deviceNoun: String { platform.deviceNoun }
    private var device: String { platform.deviceNounStart }
    private var secret: String { platform == .mac ? "password" : "passcode" }
    private var settings: String { platform.settingsApp }
    /// The biometry at the start of a sentence.
    private var biometryStart: String { biometry.prefix(1).uppercased() + biometry.dropFirst() }

    var clockSkew: String { "The clocks of \(deviceNoun) and the computer differ by more than 10 minutes" }
    var noKey: String { "\(device) has no key for the computer. Run: sudo flux-cli approve enroll" }
    var anotherOpen: String { "Another request is open on \(deviceNoun)" }
    func enrollTitle(host: String) -> String { "Enroll \(deviceNoun) on \(host)?" }
    func enrollDetail(computer: String) -> String {
        "Flux makes a key for \(computer) in the Secure Enclave of \(deviceNoun). Each approval then needs \(biometry)."
    }
    func enrollReplaces(computer: String) -> String { "This replaces the current approval key for \(computer)." }
    func enrollQuestion(user: String, host: String) -> String { "Use \(deviceNoun) to approve sudo for user \(user) on host \(host)?" }
    func enrollReason(user: String, host: String) -> String { "enroll \(deviceNoun) to approve sudo for \(user) on \(host)" }

    var biometryChanged: String {
        let what = platform == .mac ? "The fingerprints" : biometryStart
        return "\(what) on \(deviceNoun) changed. Enroll again with: sudo flux-cli approve enroll"
    }
    var saveFailed: String { "\(device) could not save its approval key." }
    var notEnrolled: String { "Set up \(biometry) in \(settings) first." }
    var lockedOut: String { "\(biometryStart) is locked. Unlock \(deviceNoun) with the \(secret) first." }
    var unavailable: String {
        platform == .mac
            ? "\(biometryStart) is not available. Open the lid of \(deviceNoun), or connect a keyboard with \(biometry)."
            : "\(biometryStart) is not available on \(deviceNoun)."
    }
    var unavailableShort: String { "\(biometryStart) is not available." }
    var notRecognized: String {
        guard let trait else { return "The \(secret) was wrong." }
        return "\(biometryStart) did not recognize the \(trait)."
    }
    var deviceLocked: String { "\(device) is locked, so it cannot use its approval key." }
    var makeFailed: String { "\(device) could not make its approval key." }
    var useFailed: String { "\(device) could not use its approval key." }
    /// Why a device without a Secure Enclave, such as the simulator, cannot
    /// approve.
    public var noSecureEnclave: String { "\(device) has no Secure Enclave, so it cannot keep an approval key." }

    /// The SF Symbol of the biometry.
    public var symbol: String {
        switch trait {
        case "face": "faceid"
        case "eye": "opticid"
        case "fingerprint": "touchid"
        default: "lock"
        }
    }

    /// The hint while the biometry runs.
    public var working: String {
        switch trait {
        case "face", "eye": "Look at \(deviceNoun)."
        case "fingerprint": "Touch the \(biometry) sensor."
        default: "Enter \(biometry)."
        }
    }
}
