import XCTest
@testable import FluxKit

final class PlatformTextTests: XCTestCase {
    func testNouns() {
        XCTAssertEqual(FluxPlatform.mac.deviceNoun, "this Mac")
        XCTAssertEqual(FluxPlatform.mac.deviceNounStart, "This Mac")
        XCTAssertEqual(FluxPlatform.mac.settingsApp, "System Settings")
        XCTAssertEqual(FluxPlatform.phone.deviceNoun, "this iPhone")
        XCTAssertEqual(FluxPlatform.phone.deviceNounStart, "This iPhone")
        XCTAssertEqual(FluxPlatform.phone.settingsApp, "Settings")
    }

    func testCurrent() {
        #if os(macOS)
        XCTAssertEqual(FluxPlatform.current, .mac)
        #else
        XCTAssertEqual(FluxPlatform.current, .phone)
        #endif
    }

    /// The Mac texts are the ones that Flux for macOS always showed.
    func testMacTextsStayTheSame() {
        XCTAssertEqual(Device.unpairedText(computer: "roger", platform: .mac), "roger unpaired this Mac")
        XCTAssertEqual(MicPlugin.updateText(computer: "roger", platform: .mac), "Update Flux on roger to use this Mac as a microphone")
        XCTAssertEqual(MicPlugin.noMicrophoneText(platform: .mac), "This Mac has no microphone")
        XCTAssertEqual(WebcamPlugin.updateText(computer: "roger", platform: .mac), "Update Flux on roger to use this Mac as a webcam")
        XCTAssertEqual(WebcamPlugin.noCameraText(platform: .mac), "This Mac has no usable camera")
        XCTAssertEqual(DesktopPlugin.cannotShowText(platform: .mac), "This Mac cannot show the stream")
        XCTAssertEqual(DictationText.unsupported(["en-GB"], platform: .mac),
                       "The speech recognizer of this Mac supports none of its languages: English (United Kingdom). Choose a language.")
        XCTAssertEqual(DictationText.notSupported("de-DE", platform: .mac),
                       "The speech recognizer of this Mac does not support German (Germany). Choose another language.")
        XCTAssertEqual(DictationText.noMicrophone(platform: .mac), "This Mac has no microphone input. Connect a microphone, then try again.")
        XCTAssertEqual(DictationText.message(domain: NSURLErrorDomain, code: -1009, description: "offline", platform: .mac),
                       "Apple's speech servers are not reachable. Check the network, or choose a language that this Mac transcribes on the device.")
        XCTAssertEqual(DictationText.speechDenied(platform: .mac), "Allow Flux in System Settings > Privacy & Security > Speech Recognition to dictate")
        XCTAssertEqual(DictationText.micDenied(platform: .mac), "Allow Flux in System Settings > Privacy & Security > Microphone to dictate")
        XCTAssertEqual(MicPlugin.deniedText(platform: .mac), "Allow the microphone for Flux in System Settings > Privacy & Security > Microphone")
        XCTAssertEqual(CameraSource.accessMessage(platform: .mac), "Flux has no access to the camera. Allow Flux in System Settings, Privacy & Security, Camera.")
    }

    func testPhoneTexts() {
        XCTAssertEqual(Device.unpairedText(computer: "roger", platform: .phone), "roger unpaired this iPhone")
        XCTAssertEqual(MicPlugin.updateText(computer: "roger", platform: .phone), "Update Flux on roger to use this iPhone as a microphone")
        XCTAssertEqual(MicPlugin.noMicrophoneText(platform: .phone), "This iPhone has no microphone")
        XCTAssertEqual(WebcamPlugin.updateText(computer: "roger", platform: .phone), "Update Flux on roger to use this iPhone as a webcam")
        XCTAssertEqual(WebcamPlugin.noCameraText(platform: .phone), "This iPhone has no usable camera")
        XCTAssertEqual(DesktopPlugin.cannotShowText(platform: .phone), "This iPhone cannot show the stream")
        XCTAssertEqual(DictationText.noMicrophone(platform: .phone), "This iPhone has no microphone input. Connect a microphone, then try again.")
        XCTAssertTrue(DictationText.unsupported(["en-GB"], platform: .phone).hasPrefix("The speech recognizer of this iPhone "))
        XCTAssertTrue(DictationText.notSupported("de-DE", platform: .phone).hasPrefix("The speech recognizer of this iPhone "))
        XCTAssertTrue(DictationText.message(domain: NSURLErrorDomain, code: -1009, description: "offline", platform: .phone)
            .hasSuffix("a language that this iPhone transcribes on the device."))
        XCTAssertEqual(DictationText.speechDenied(platform: .phone), "Allow Flux in Settings > Privacy & Security > Speech Recognition to dictate")
        XCTAssertEqual(DictationText.micDenied(platform: .phone), "Allow Flux in Settings > Privacy & Security > Microphone to dictate")
        XCTAssertEqual(MicPlugin.deniedText(platform: .phone), "Allow the microphone for Flux in Settings > Privacy & Security > Microphone")
        XCTAssertEqual(CameraSource.accessMessage(platform: .phone), "Flux has no access to the camera. Allow Flux in Settings, Privacy & Security, Camera.")
    }

    /// Received files name the folder. The default folder on iOS is the
    /// Documents folder of the app, which the Files app shows.
    func testReceivedFolderName() {
        XCTAssertEqual(SharePlugin.placeName(FluxFolders.downloads), FluxFolders.downloadsName)
        XCTAssertEqual(SharePlugin.placeName(URL(fileURLWithPath: "/tmp/Inbox", isDirectory: true)), "Inbox")
        #if os(macOS)
        XCTAssertEqual(SharePlugin.placeName(FluxFolders.downloads), "Downloads")
        #else
        XCTAssertNotEqual(SharePlugin.placeName(FluxFolders.downloads), "Documents")
        #endif
    }
}
