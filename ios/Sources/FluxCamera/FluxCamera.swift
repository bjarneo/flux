import Foundation

/// Camera mode stubs. Full AVFoundation + Vision + VisionKit ports land in M5.
/// Desktop `flux webcam` CLI + PHONE CAMERA card are reused unchanged.
public enum CameraMode: String, Sendable, CaseIterable {
    case text, qr, photo, document, webcam
}
