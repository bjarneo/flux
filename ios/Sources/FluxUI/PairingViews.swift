import SwiftUI
import FluxCore
import FluxProto

/// Incoming pairing request: compare the 8-char key with the desktop, then
/// Accept. Mirrors Android's pair dialog and the desktop
/// "Check that the phone shows …" notification.
public struct PairView: View {
    public var deviceName: String
    public var verificationKey: String
    public var onAccept: () -> Void
    public var onDecline: () -> Void

    public init(deviceName: String, verificationKey: String, onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.deviceName = deviceName
        self.verificationKey = verificationKey
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Pair with \(deviceName)?")
                .font(.headline)
            Text("Check that the computer shows the same key.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verificationKey)
                .font(.system(.title, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("Verification key \(verificationKey)")
            HStack {
                Button("Decline", action: onDecline)
                    .buttonStyle(.bordered)
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

/// Outgoing pairing request: waiting for the desktop side to accept.
public struct OutgoingPairView: View {
    public var deviceName: String
    public var verificationKey: String
    public var onCancel: () -> Void

    public init(deviceName: String, verificationKey: String, onCancel: @escaping () -> Void) {
        self.deviceName = deviceName
        self.verificationKey = verificationKey
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Pairing with \(deviceName)…")
                .font(.headline)
            Text("The computer must show \(verificationKey). Accept it there.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

/// Unpair confirmation. Unpairing removes trust on both sides: the phone
/// deletes the pin and sends `{"pair": false}`.
public struct UnpairView: View {
    public var deviceName: String
    public var onUnpair: () -> Void
    public var onCancel: () -> Void

    public init(deviceName: String, onUnpair: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.deviceName = deviceName
        self.onUnpair = onUnpair
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Unpair \(deviceName)?")
                .font(.headline)
            Text("This removes the pinned certificate. Pairing again needs a key comparison.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Unpair", role: .destructive, action: onUnpair)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct PairingViews_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PairView(deviceName: "omarchy-xps", verificationKey: "5EE6825F", onAccept: {}, onDecline: {})
                .previewDisplayName("pair")
            OutgoingPairView(deviceName: "omarchy-xps", verificationKey: "5EE6825F", onCancel: {})
                .previewDisplayName("pair outgoing")
            UnpairView(deviceName: "omarchy-xps", onUnpair: {}, onCancel: {})
                .previewDisplayName("unpair")
        }
    }
}
