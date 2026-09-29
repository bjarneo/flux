import XCTest
#if canImport(AVFoundation)
@testable import FluxStream
import FluxProto

/// `MicProducer` glue: tap chunks reach the live stream, levels reach the
/// meter, stop finishes the stream, and a failed start holds nothing. The
/// tap itself is hardware (`MicCapture`); a stub stands in here.
final class MicProducerTests: XCTestCase {
    final class StubSource: MicChunkSource, @unchecked Sendable {
        private let lock = NSLock()
        var onChunk: ((Data, Float) -> Void)?
        var started = 0
        var stopped = 0
        var error: Error?

        func start() throws {
            lock.withLock { started += 1 }
            if let error { throw error }
        }

        func stop() {
            lock.withLock { stopped += 1 }
        }
    }

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        var bytes: [Data] = []
        var levels: [Float] = []
        var finished = false

        func append(_ d: Data) { lock.withLock { bytes.append(d) } }
        func level(_ f: Float) { lock.withLock { levels.append(f) } }
        func markFinished() { lock.withLock { finished = true } }
    }

    struct Boom: Error, Equatable {}

    func testChunksAndLevelsFlow() async throws {
        let stub = StubSource()
        let producer = MicProducer(makeCapture: { stub })
        let sink = Sink()
        producer.onLevel = { sink.level($0) }
        let stream = try producer.start()
        let chunks = [Data([1, 2, 3]), Data([4, 5]), Data([6])]
        for (i, chunk) in chunks.enumerated() {
            stub.onChunk?(chunk, Float(i) * 0.25)
        }
        stub.onChunk?(Data([7]), -1) // bytes flow, meter stays silent
        producer.stop()
        for await part in stream { sink.append(part) }
        sink.markFinished()
        XCTAssertEqual(chunks + [Data([7])], sink.bytes)
        XCTAssertEqual([0, 0.25, 0.5], sink.levels)
        XCTAssertTrue(sink.finished)
    }

    func testFailedStartHoldsNothing() {
        let stub = StubSource()
        stub.error = Boom()
        let producer = MicProducer(makeCapture: { stub })
        XCTAssertThrowsError(try producer.start()) { XCTAssertTrue($0 is Boom) }
        // Nothing started, so nothing to stop — and a retry works.
        producer.stop()
        let retry = StubSource()
        let retrying = MicProducer(makeCapture: { retry })
        XCTAssertNotNil(try? retrying.start())
        retrying.stop()
        XCTAssertEqual(1, retry.stopped)
    }

    func testRestartStopsFirst() async {
        let stub = StubSource()
        let producer = MicProducer(makeCapture: { stub })
        let first = try? producer.start()
        stub.onChunk?(Data([1]), 0.5)
        let second = try? producer.start()
        XCTAssertNotNil(second)
        // The first stream is finished by the restart…
        var firstParts: [Data] = []
        if let first {
            for await part in first { firstParts.append(part) }
        }
        XCTAssertEqual([Data([1])], firstParts)
        producer.stop()
        // …and the tap stopped exactly twice (restart + final stop).
        XCTAssertEqual(2, stub.stopped)
    }
}
#endif
