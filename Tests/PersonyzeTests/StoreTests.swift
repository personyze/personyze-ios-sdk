import Foundation
import Testing
@testable import Personyze

struct StoreTests
{	@Test func fileStoreRoundTrip() throws
	{	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("personyze-test-" + UUID().uuidString)
		defer
		{	try? FileManager.default.removeItem(at: dir)
		}
		let store = FileStore(dir: dir)
		#expect(store.read("state.json") == nil)
		store.write("state.json", "{\"v\":1}")
		store.write("state.json", "{\"v\":2} שלום", sync: true)
		#expect(store.read("state.json") == "{\"v\":2} שלום")
		store.write("outbox.json", "[]")
		store.quarantine("state.json")
		#expect(store.read("state.json") == nil)
		#expect(store.read("state.json.corrupt") == "{\"v\":2} שלום")
		store.delete("outbox.json")
		#expect(store.read("outbox.json") == nil)
		#expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json.corrupt"])
		store.clear()
		#expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [])
	}

	@Test func memoryStoreQuarantines()
	{	let store = MemoryStore()
		store.write("a", "1")
		store.quarantine("a")
		#expect(store.names == ["a.corrupt"])
	}
}

/// The engine runs anywhere Swift does; the iOS frameworks stay out of `Core`. On Linux an import of
/// one would not compile at all - this catches it on a Mac, where it would.
struct CoreIsPlatformFreeTests
{	@Test func coreImportsNoAppleFramework() throws
	{	let core = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Sources/Personyze/Core")
		let files = try FileManager.default.contentsOfDirectory(atPath: core.path).filter { $0.hasSuffix(".swift") }
		#expect(!files.isEmpty)
		let allowed: Set<String> = ["Foundation", "FoundationNetworking", "Dispatch"]
		var offenders: [String] = []
		for file in files.sorted()
		{	let text = try String(contentsOf: core.appendingPathComponent(file), encoding: .utf8)
			for line in text.split(separator: "\n") where line.hasPrefix("import ")
			{	let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
				if !allowed.contains(module)
				{	offenders.append("\(file): \(line)")
				}
			}
		}
		#expect(offenders == [])
	}
}
