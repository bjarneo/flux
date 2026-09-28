import AVFoundation

/// The cameras of an iPhone as Flux offers them: 1 back camera and 1 front
/// camera, with the ids "back" and "front" of Flux for Android, then the
/// cameras on USB-C.
enum PhoneCameras {
    /// A camera that AVFoundation found.
    struct Found: Equatable {
        let uniqueID: String
        let name: String
        let position: AVCaptureDevice.Position
        /// True for a wide-angle camera, the main lens of its side.
        let wide: Bool
    }

    /// A camera that Flux offers.
    struct Picked: Equatable {
        /// "back", "front", or the lower-case name of an external camera.
        let id: String
        let uniqueID: String
        let name: String
    }

    #if os(iOS)
    /// The cameras that Flux offers on this iPhone.
    static func available() -> [Picked] { pick(found()) }

    /// The cameras of this iPhone.
    private static func found() -> [Found] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera, .external,
        ]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices.map {
            Found(uniqueID: $0.uniqueID, name: $0.localizedName, position: $0.position, wide: $0.deviceType == .builtInWideAngleCamera)
        }
    }
    #endif

    /// Picks the wide-angle camera of each side, or another lens of a side
    /// without one, back first. External cameras follow in their order.
    static func pick(_ found: [Found]) -> [Picked] {
        var picked: [Picked] = []
        for (position, id) in [(AVCaptureDevice.Position.back, "back"), (.front, "front")] {
            let side = found.filter { $0.position == position }
            if let camera = side.first(where: \.wide) ?? side.first {
                picked.append(Picked(id: id, uniqueID: camera.uniqueID, name: camera.name))
            }
        }
        var seen: [String: Int] = [:]
        for camera in found where camera.position == .unspecified {
            let name = camera.name.trimmingCharacters(in: .whitespaces)
            let n = (seen[name.lowercased()] ?? 0) + 1
            seen[name.lowercased()] = n
            let label = n == 1 ? name : "\(name) \(n)"
            picked.append(Picked(id: label.lowercased(), uniqueID: camera.uniqueID, name: label))
        }
        return picked
    }
}
