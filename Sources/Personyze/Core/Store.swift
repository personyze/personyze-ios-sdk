import Foundation

/// Named text files. Writes are atomic: a reader sees the old file or the new one, never half.
protocol Store: Sendable
{	func read(_ name: String) -> String?
	/// `sync`: on disk before this returns, for state that must survive the process dying next.
	func write(_ name: String, _ text: String, sync: Bool)
	func delete(_ name: String)
	/// Keep the file but move it aside (a corrupt state, for a later look).
	func quarantine(_ name: String)
	func clear()
}

extension Store
{	func write(_ name: String, _ text: String)
	{	write(name, text, sync: false)
	}
}

/// Plain files in `dir`, written to `name.tmp` and renamed over the old one. The SDK is the only
/// writer (one engine per storage name and process), so there is no locking between processes.
///
/// The directory is the caller's to choose. On iOS it must be excluded from backup: restored onto
/// the user's next phone, the install's anonymous id would make two devices one visitor
/// (SPEC section 11).
final class FileStore: Store, @unchecked Sendable
{	let dir: URL
	private let lock = NSLock()

	init(dir: URL)
	{	self.dir = dir
	}

	func read(_ name: String) -> String?
	{	lock.locked
		{	guard let data = FileManager.default.contents(atPath: file(name).path) else
			{	return nil
			}
			return String(data: data, encoding: .utf8)
		}
	}

	func write(_ name: String, _ text: String, sync: Bool)
	{	lock.locked
		{	let fm = FileManager.default
			try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
			let tmp = file(name + ".tmp")
			guard fm.createFile(atPath: tmp.path, contents: Data(text.utf8)) else
			{	return
			}
			if sync, let handle = try? FileHandle(forWritingTo: tmp)
			{	try? handle.synchronize()
				try? handle.close()
			}
			if rename(tmp.path, file(name).path) != 0
			{	try? fm.removeItem(at: tmp)
			}
		}
	}

	func delete(_ name: String)
	{	lock.locked
		{	try? FileManager.default.removeItem(at: file(name))
		}
	}

	func quarantine(_ name: String)
	{	lock.locked
		{	_ = rename(file(name).path, file(name + ".corrupt").path)
		}
	}

	func clear()
	{	lock.locked
		{	let fm = FileManager.default
			for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
			{	try? fm.removeItem(at: file(name))
			}
		}
	}

	private func file(_ name: String) -> URL
	{	dir.appendingPathComponent(name, isDirectory: false)
	}
}

/// For tests, and for an app that asks for no storage.
final class MemoryStore: Store, @unchecked Sendable
{	private let lock = NSLock()
	private var files: [String: String] = [:]

	var names: [String]
	{	lock.locked
		{	files.keys.sorted()
		}
	}

	func read(_ name: String) -> String?
	{	lock.locked
		{	files[name]
		}
	}

	func write(_ name: String, _ text: String, sync: Bool)
	{	lock.locked
		{	files[name] = text
		}
	}

	func delete(_ name: String)
	{	lock.locked
		{	files[name] = nil
		}
	}

	func quarantine(_ name: String)
	{	lock.locked
		{	if let text = files.removeValue(forKey: name)
			{	files[name + ".corrupt"] = text
			}
		}
	}

	func clear()
	{	lock.locked
		{	files.removeAll()
		}
	}
}

extension NSLock
{	/// `withLock` needs iOS 16.
	func locked<T>(_ body: () throws -> T) rethrows -> T
	{	lock()
		defer
		{	unlock()
		}
		return try body()
	}
}
