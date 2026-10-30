import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Personyze

/// A local HTTP/1.1 server for the transport tests - MockWebServer's part in the Android tests.
/// Each connection reads one request, answers the next queued response and closes.
final class TestServer: @unchecked Sendable
{	struct Response: Sendable
	{	var status = 200
		var headers: [String: String] = [:]
		var body = ""
		/// Send the body a byte at a time, this many ms apart.
		var bytePauseMs = 0
		/// Read the request, then close the connection without answering.
		var dropConnection = false
	}

	struct Request: Sendable
	{	var method: String
		var target: String
		/// Lower-case names.
		var headers: [String: String]
		var body: String
	}

	let port: Int
	private let listener: Int32
	private let lock = NSLock()
	private var responses: [Response] = []
	private var requests: [Request] = []
	private var stopped = false

	var baseUrl: String
	{	"http://127.0.0.1:\(port)"
	}

	var requestCount: Int
	{	lock.locked
		{	requests.count
		}
	}

	init()
	{	let fd = socket(AF_INET, TestServer.streamType, 0)
		precondition(fd >= 0, "socket() failed")
		var yes: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
		var addr = sockaddr_in()
		#if canImport(Darwin)
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		#endif
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = 0
		addr.sin_addr.s_addr = inet_addr("127.0.0.1")
		var len = socklen_t(MemoryLayout<sockaddr_in>.size)
		let ok = withUnsafeMutablePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
				bind(fd, sa, len) == 0 && listen(fd, 16) == 0 && getsockname(fd, sa, &len) == 0
			}
		}
		precondition(ok, "cannot listen on 127.0.0.1")
		listener = fd
		port = Int(UInt16(bigEndian: addr.sin_port))
		Thread.detachNewThread { [self] in
			acceptLoop()
		}
	}

	/// A port nothing listens on: connecting is refused.
	static func unusedPort() -> Int
	{	let server = TestServer()
		let port = server.port
		server.stop()
		usleep(200_000)
		return port
	}

	func enqueue(_ response: Response)
	{	lock.locked
		{	responses.append(response)
		}
	}

	/// The oldest request not taken yet.
	func takeRequest() -> Request?
	{	lock.locked
		{	requests.isEmpty ? nil : requests.removeFirst()
		}
	}

	func stop()
	{	lock.locked
		{	stopped = true
		}
	}

	private var isStopped: Bool
	{	lock.locked
		{	stopped
		}
	}

	private func acceptLoop()
	{	while !isStopped
		{	var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
			if poll(&pfd, 1, 50) <= 0
			{	continue
			}
			let client = accept(listener, nil, nil)
			if client >= 0
			{	DispatchQueue.global().async { [self] in
					serve(client)
				}
			}
		}
		TestServer.systemClose(listener)
	}

	private func serve(_ fd: Int32)
	{	defer
		{	TestServer.systemClose(fd)
		}
		#if canImport(Darwin)
		var yes: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
		#endif
		guard let request = readRequest(fd) else
		{	return
		}
		let queued: Response? = lock.locked
		{	requests.append(request)
			return responses.isEmpty ? nil : responses.removeFirst()
		}
		let response = queued ?? Response(status: 599, body: "no response queued")
		if response.dropConnection
		{	shutdown(fd, Int32(SHUT_RDWR))
			return
		}
		let body = Array(response.body.utf8)
		var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
		for (name, value) in response.headers
		{	head += "\(name): \(value)\r\n"
		}
		head += "\r\n"
		guard writeAll(fd, Array(head.utf8)) else
		{	return
		}
		if response.bytePauseMs > 0
		{	for b in body
			{	guard writeAll(fd, [b]) else
				{	return
				}
				usleep(UInt32(response.bytePauseMs*1000))
			}
		}
		else
		{	_ = writeAll(fd, body)
		}
	}

	private func readRequest(_ fd: Int32) -> Request?
	{	var buffer: [UInt8] = []
		var chunk = [UInt8](repeating: 0, count: 4096)
		var headEnd: Int?
		while headEnd == nil
		{	let n = recv(fd, &chunk, chunk.count, 0)
			if n <= 0
			{	return nil
			}
			buffer += chunk[0 ..< n]
			headEnd = TestServer.find(Array("\r\n\r\n".utf8), in: buffer)
		}
		guard let headEnd else
		{	return nil
		}
		var lines = String(decoding: buffer[0 ..< headEnd], as: UTF8.self).components(separatedBy: "\r\n")
		let requestLine = lines.removeFirst().split(separator: " ")
		guard requestLine.count >= 2 else
		{	return nil
		}
		var headers: [String: String] = [:]
		for line in lines
		{	if let colon = line.firstIndex(of: ":")
			{	headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			}
		}
		let length = Int(headers["content-length"] ?? "") ?? 0
		var body = Array(buffer[(headEnd + 4)...])
		while body.count < length
		{	let n = recv(fd, &chunk, chunk.count, 0)
			if n <= 0
			{	break
			}
			body += chunk[0 ..< n]
		}
		return Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: String(decoding: body, as: UTF8.self))
	}

	private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool
	{	var offset = 0
		while offset < bytes.count
		{	let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, TestServer.sendFlags) }
			if n <= 0
			{	return false
			}
			offset += n
		}
		return true
	}

	private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int?
	{	if haystack.count < needle.count
		{	return nil
		}
		for i in 0 ... haystack.count - needle.count where haystack[i ..< i + needle.count].elementsEqual(needle)
		{	return i
		}
		return nil
	}

	private static func systemClose(_ fd: Int32)
	{	#if canImport(Glibc)
		_ = Glibc.close(fd)
		#else
		_ = Darwin.close(fd)
		#endif
	}

	#if canImport(Glibc)
	private static let streamType = Int32(SOCK_STREAM.rawValue)
	/// A peer gone mid-body must fail the write, not kill the test process with SIGPIPE.
	private static let sendFlags = Int32(MSG_NOSIGNAL)
	#else
	private static let streamType = SOCK_STREAM
	private static let sendFlags: Int32 = 0
	#endif
}
