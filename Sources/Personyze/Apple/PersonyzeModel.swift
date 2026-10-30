#if canImport(Combine)
import Combine
import Foundation

/// The current decision and visitor, for SwiftUI on every iOS the SDK supports:
///
/// ```swift
/// struct HomeScreen: View
/// {	@StateObject private var personyze = PersonyzeModel()
///
/// 	var body: some View
/// 	{	VStack
/// 		{	if let banner = personyze.result.actions(in: "Home banner").first
/// 			{	PersonyzeActionContent(banner)
/// 			}
/// 		}
/// 		.task
/// 		{	await Personyze.navigate("Home")
/// 		}
/// 	}
/// }
/// ```
///
/// Create it after `Personyze.initialize`: it follows the client there was when it was made.
@MainActor
public final class PersonyzeModel: ObservableObject
{	@Published public private(set) var result: PersonyzeResult
	@Published public private(set) var visitor: PersonyzeVisitor

	private let subscriptions = Subscriptions()

	public init(client: PersonyzeClient? = Personyze.client)
	{	result = client?.result ?? .empty
		visitor = client?.visitor ?? Personyze.visitor
		guard let client else
		{	return
		}
		subscriptions.add(
			Task { [weak self] in
				for await value in client.results
				{	self?.result = value
				}
			}
		)
		subscriptions.add(
			Task { [weak self] in
				for await value in client.visitors
				{	self?.visitor = value
				}
			}
		)
	}
}

/// The model's stream readers, stopped with it.
private final class Subscriptions: @unchecked Sendable
{	private let lock = NSLock()
	private var tasks: [Task<Void, Never>] = []

	func add(_ task: Task<Void, Never>)
	{	lock.locked
		{	tasks.append(task)
		}
	}

	deinit
	{	for task in tasks
		{	task.cancel()
		}
	}
}
#endif
