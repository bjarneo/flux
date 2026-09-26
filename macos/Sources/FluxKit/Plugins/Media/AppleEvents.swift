import Carbon
import Foundation

/// A failed Apple Event, with the status of the Apple Event Manager.
struct AppleEventError: Error, CustomStringConvertible {
    let app: String
    let status: OSStatus

    var description: String {
        switch Int(status) {
        case errAEEventNotPermitted:
            return "\(app): Apple Events not permitted (\(status)). Allow Flux in System Settings > Privacy & Security > Automation"
        case errAEEventWouldRequireUserConsent:
            return "\(app): Apple Events wait for the user to allow them (\(status))"
        case procNotFound:
            return "\(app) is not running (\(status))"
        case errAENoSuchObject:
            return "\(app) has no such object (\(status))"
        case errAETimeout:
            return "\(app) did not answer in time (\(status))"
        default:
            return "\(app): Apple Event failed (\(status))"
        }
    }
}

/// The four-char codes of the scripting terms of one app, read from its
/// scripting definition. Terms such as "player state" or "next track" name
/// the same thing in every app, while their codes differ between apps.
struct ScriptingTerms: Sendable {
    let app: String
    private var codes: [String: FourCharCode] = [:]
    private var commands: [String: CommandCode] = [:]

    struct CommandCode: Sendable {
        let eventClass: AEEventClass
        let eventID: AEEventID
    }

    init(app: String, url: URL) throws {
        self.app = app
        var out: Unmanaged<CFData>?
        let status = OSACopyScriptingDefinitionFromURL(url as CFURL, 0, &out)
        guard status == noErr, let data = out?.takeRetainedValue() as Data? else {
            throw AppleEventError(app: app, status: OSStatus(status))
        }
        // A tree walk, not XPath: the XQuery engine behind XPath locks stdin
        // and waits while any other thread reads from it.
        var stack = [try XMLDocument(data: data).rootElement()].compactMap { $0 }
        while let e = stack.popLast() {
            stack.append(contentsOf: (e.children ?? []).reversed().compactMap { $0 as? XMLElement })
            guard let kind = e.name, let name = e.attribute(forName: "name")?.stringValue,
                  let code = e.attribute(forName: "code")?.stringValue else { continue }
            switch kind {
            case "property", "class", "enumerator":
                if codes["\(kind):\(name)"] == nil, let value = fourCharCode(code) { codes["\(kind):\(name)"] = value }
            case "command":
                guard code.utf8.count == 8, commands[name] == nil,
                      let cls = fourCharCode(String(code.prefix(4))), let id = fourCharCode(String(code.suffix(4))) else { continue }
                commands[name] = CommandCode(eventClass: cls, eventID: id)
            default:
                continue
            }
        }
    }

    func property(_ name: String) throws -> FourCharCode { try code("property", name) }
    func type(_ name: String) throws -> FourCharCode { try code("class", name) }
    func enumerator(_ name: String) -> FourCharCode? { codes["enumerator:\(name)"] }
    func command(_ name: String) -> CommandCode? { commands[name] }

    private func code(_ kind: String, _ name: String) throws -> FourCharCode {
        guard let c = codes["\(kind):\(name)"] else { throw FluxError("\(app) has no \(kind) “\(name)”") }
        return c
    }
}

/// Converts a code such as "pPlS" to its number.
func fourCharCode(_ s: String) -> FourCharCode? {
    guard let bytes = s.data(using: .macOSRoman), bytes.count == 4 else { return nil }
    return bytes.reduce(0) { $0 << 8 | FourCharCode($1) }
}

/// Sends Apple Events to one running app. The address is the process ID, so
/// that an event never launches an app that quit.
struct AppleEventTarget {
    let terms: ScriptingTerms
    let address: NSAppleEventDescriptor
    var app: String { terms.app }

    init(terms: ScriptingTerms, pid: pid_t) {
        self.terms = terms
        address = NSAppleEventDescriptor(processIdentifier: pid)
    }

    /// Reports whether this process may send Apple Events to the app. With
    /// ask, macOS asks the user and the call blocks until the user answers.
    static func permission(_ address: NSAppleEventDescriptor, ask: Bool) -> OSStatus {
        guard let desc = address.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    /// The property of the container. The default container is the application.
    func property(_ name: String, of container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        specifier(FourCharCode(cProperty), form: FourCharCode(formPropertyID), NSAppleEventDescriptor(typeCode: try terms.property(name)), container)
    }

    /// The element of the class at a 1-based index.
    func element(_ className: String, _ index: Int32, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        specifier(try terms.type(className), form: FourCharCode(formAbsolutePosition), NSAppleEventDescriptor(int32: index), container)
    }

    /// The value of the object, or nil for a missing value.
    func get(_ object: NSAppleEventDescriptor, timeout: TimeInterval = 5) throws -> NSAppleEventDescriptor? {
        let e = event(AEEventClass(kAECoreSuite), AEEventID(kAEGetData))
        e.setParam(object, forKeyword: AEKeyword(keyDirectObject))
        guard let v = try send(e, timeout: timeout).paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return nil }
        if v.descriptorType == DescType(typeType), v.typeCodeValue == missingValue { return nil }
        return v
    }

    func set(_ object: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        let e = event(AEEventClass(kAECoreSuite), AEEventID(kAESetData))
        e.setParam(object, forKeyword: AEKeyword(keyDirectObject))
        e.setParam(value, forKeyword: AEKeyword(keyAEData))
        _ = try send(e)
    }

    /// Runs the first command of the list that the app has.
    func command(_ names: [String]) throws {
        guard let code = names.lazy.compactMap({ terms.command($0) }).first else {
            throw FluxError("\(app) has no command “\(names.joined(separator: "” or “"))”")
        }
        _ = try send(event(code.eventClass, code.eventID))
    }

    private func specifier(_ want: FourCharCode, form: FourCharCode, _ data: NSAppleEventDescriptor, _ container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        r.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        r.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        r.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return r.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? r
    }

    private func event(_ eventClass: AEEventClass, _ eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(withEventClass: eventClass, eventID: eventID, targetDescriptor: address,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    private func send(_ e: NSAppleEventDescriptor, timeout: TimeInterval = 5) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try e.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch let error as NSError {
            throw AppleEventError(app: app, status: OSStatus(truncatingIfNeeded: error.code))
        }
        if let n = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, n != 0 {
            throw AppleEventError(app: app, status: n)
        }
        return reply
    }
}

private let missingValue = fourCharCode("msng")!
