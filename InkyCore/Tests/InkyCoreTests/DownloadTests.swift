import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import InkyCore

/// Answers every request with a body of the size the URL asks for, and
/// says how long it is only if the URL asks for that too.
private final class SizedAnswer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        let size = items.first { $0.name == "size" }.flatMap { $0.value.flatMap(Int.init) } ?? 0
        let saysLength = items.contains { $0.name == "length" }
        var headers: [String: String] = [:]
        if saysLength { headers["Content-Length"] = String(size) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a network delivers it.
        var sent = 0
        while sent < size {
            let piece = min(64 << 10, size - sent)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: piece))
            sent += piece
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct DownloadTests {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SizedAnswer.self]
        return URLSession(configuration: configuration)
    }()

    private func url(size: Int, saysLength: Bool) -> URL {
        URL(string: "https://example.com/file?size=\(size)\(saysLength ? "&length" : "")")!
    }

    @Test func readsAnAnswerUpToTheLimit() async throws {
        for saysLength in [true, false] {
            let answer = try await Download.fetch(url(size: 1000, saysLength: saysLength), limit: 1000, session: session)
            #expect(answer.data.count == 1000)
            #expect(answer.status == 200)
        }
    }

    @Test func refusesAnAnswerLongerThanTheLimit() async {
        // Whether the server says so up front or only sends more.
        for saysLength in [true, false] {
            await #expect(throws: URLError.self) {
                try await Download.fetch(url(size: 3 << 20, saysLength: saysLength), limit: 1 << 20, session: session)
            }
        }
    }
}

@Suite struct FaviconImageTests {
    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func keepsWhatIsTheSizeOfAnIcon() {
        #expect(Favicon.isImage(png(width: 32, height: 32)))
        #expect(Favicon.isImage(png(width: 256, height: 256)))
    }

    @Test func refusesWhatIsNotAnIcon() {
        #expect(!Favicon.isImage(Data("<html>Not found</html>".utf8)))
        #expect(!Favicon.isImage(png(width: 4096, height: 16)))
        #expect(!Favicon.isImage(png(width: 16, height: 4096)))
    }
}
