import Foundation

/// A mutex for async code: one holder at a time, waiters served in order. A waiter can give up at
/// a deadline - a decision that cannot get the wire in time fails rather than arrives late.
final class AsyncMutex: @unchecked Sendable
{	private let state = NSLock()
	private var held = false
	private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
	private var nextId = 0

	func lock() async
	{	_ = await lock(timeoutMs: nil)
	}

	/// False when it was not free within `timeoutMs`.
	func lock(timeoutMs: Int64?) async -> Bool
	{	let id = state.locked
		{	nextId += 1
			return nextId
		}
		return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
			let acquired = state.locked
			{	if !held
				{	held = true
					return true
				}
				waiters.append((id, continuation))
				return false
			}
			if acquired
			{	continuation.resume(returning: true)
			}
			else if let timeoutMs
			{	DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(max(timeoutMs, 0)))) { [self] in
					let expired = state.locked
					{	() -> CheckedContinuation<Bool, Never>? in
						guard let i = waiters.firstIndex(where: { $0.id == id }) else
						{	return nil
						}
						return waiters.remove(at: i).continuation
					}
					expired?.resume(returning: false)
				}
			}
		}
	}

	/// Hands the mutex to the next waiter, or frees it.
	func unlock()
	{	let next = state.locked
		{	() -> CheckedContinuation<Bool, Never>? in
			if waiters.isEmpty
			{	held = false
				return nil
			}
			return waiters.removeFirst().continuation
		}
		next?.resume(returning: true)
	}

	func withLock<T>(_ body: () async -> T) async -> T
	{	await lock()
		defer
		{	unlock()
		}
		return await body()
	}
}

/// Closed until `open()`; then every `wait()` returns at once.
final class Latch: @unchecked Sendable
{	private let state = NSLock()
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func open()
	{	let waiting = state.locked
		{	() -> [CheckedContinuation<Void, Never>] in
			if isOpen
			{	return []
			}
			isOpen = true
			defer
			{	waiters = []
			}
			return waiters
		}
		for continuation in waiting
		{	continuation.resume()
		}
	}

	func wait() async
	{	await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let now = state.locked
			{	if isOpen
				{	return true
				}
				waiters.append(continuation)
				return false
			}
			if now
			{	continuation.resume()
			}
		}
	}
}

/// The engine's own tasks: template fetches, the delayed send, requests whose caller stopped
/// waiting. Tracked so a test can wait until the engine is idle, and a closed client stops them.
final class TaskSet: @unchecked Sendable
{	private struct Entry
	{	let cancel: @Sendable () -> Void
		let wait: @Sendable () async -> Void
	}

	private let state = NSLock()
	private var tasks: [Int: Entry] = [:]
	private var nextId = 0
	private var closed = false

	@discardableResult
	func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never>
	{	state.lock()
		defer
		{	state.unlock()
		}
		nextId += 1
		let id = nextId
		// Registered before the task can finish: its last step takes the same lock.
		let task = Task { [weak self] () -> T in
			let value = await operation()
			self?.finished(id)
			return value
		}
		if closed
		{	task.cancel()
		}
		tasks[id] = Entry(cancel: { task.cancel() }, wait: { _ = await task.value })
		return task
	}

	private func finished(_ id: Int)
	{	state.locked
		{	tasks[id] = nil
		}
	}

	/// Returns once no task is left, the ones started meanwhile included.
	func idle() async
	{	while true
		{	let pending = state.locked
			{	Array(tasks.values)
			}
			if pending.isEmpty
			{	return
			}
			for entry in pending
			{	await entry.wait()
			}
		}
	}

	func cancelAll()
	{	let all = state.locked
		{	closed = true
			return Array(tasks.values)
		}
		for entry in all
		{	entry.cancel()
		}
	}
}

/// Waits for `task` at most `timeoutMs`; the task itself goes on.
func waitAtMost(_ timeoutMs: Int64, for task: Task<Void, Never>) async
{	let signal = OnceSignal()
	await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
		signal.arm(continuation)
		Task {
			await task.value
			signal.fire()
		}
		DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(max(timeoutMs, 1)))) {
			signal.fire()
		}
	}
}

/// Resumes a continuation once, whichever of several events comes first.
final class OnceSignal: @unchecked Sendable
{	private let state = NSLock()
	private var continuation: CheckedContinuation<Void, Never>?
	private var fired = false

	func arm(_ continuation: CheckedContinuation<Void, Never>)
	{	let now = state.locked
		{	if fired
			{	return true
			}
			self.continuation = continuation
			return false
		}
		if now
		{	continuation.resume()
		}
	}

	func fire()
	{	let waiting = state.locked
		{	() -> CheckedContinuation<Void, Never>? in
			if fired
			{	return nil
			}
			fired = true
			defer
			{	continuation = nil
			}
			return continuation
		}
		waiting?.resume()
	}
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable
{	private let state = NSLock()
	private var current: Value

	init(_ value: Value)
	{	current = value
	}

	var value: Value
	{	get
		{	state.locked
			{	current
			}
		}
		set
		{	state.locked
			{	current = newValue
			}
		}
	}

	func withLock<R>(_ body: (inout Value) -> R) -> R
	{	state.locked
		{	body(&current)
		}
	}
}

/// A weak reference behind a lock - an object that refers to its owner without keeping it.
final class WeakRef<Object: AnyObject>: @unchecked Sendable
{	private let state = NSLock()
	private weak var current: Object?

	var value: Object?
	{	get
		{	state.locked
			{	current
			}
		}
		set
		{	state.locked
			{	current = newValue
			}
		}
	}
}

/// A current value and its changes - the engine's result and visitor, as Kotlin's `StateFlow`.
/// Equal values are not announced again.
final class StateCell<Value: Sendable & Equatable>: @unchecked Sendable
{	private let state = NSLock()
	private var current: Value
	private var observers: [Int: AsyncStream<Value>.Continuation] = [:]
	private var nextId = 0

	init(_ value: Value)
	{	current = value
	}

	var value: Value
	{	state.locked
		{	current
		}
	}

	func set(_ value: Value)
	{	state.locked
		{	if value != current
			{	current = value
				// Under the lock, so two setters cannot reach an observer in the wrong order.
				for observer in observers.values
				{	observer.yield(value)
				}
			}
		}
	}

	/// The current value, then every change. An observer that falls behind gets the newest.
	func stream() -> AsyncStream<Value>
	{	AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
			let id = state.locked
			{	nextId += 1
				observers[nextId] = continuation
				continuation.yield(current)
				return nextId
			}
			continuation.onTermination = { [weak self] _ in
				self?.removeObserver(id)
			}
		}
	}

	private func removeObserver(_ id: Int)
	{	state.locked
		{	observers[id] = nil
		}
	}
}
