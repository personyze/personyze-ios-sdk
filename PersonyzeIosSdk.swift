//
//  PersonyzeIosSdk.swift
//  Personyze SDK Demo
//
//  Created by Jeremiah Shaulov on 3/7/19.
//  Copyright © 2019 Personyze. All rights reserved.
//

import UIKit
import WebKit
import os.log

public class PersonyzeCondition : NSObject, NSCoding
{	public internal(set) var id: Int = 0
	public internal(set) var name: String? = nil

	public init(id: Int)
	{	self.id = id
	}

	fileprivate func fromStorage() -> Bool
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Condition \(id).dat").path
		if let myself = NSKeyedUnarchiver.unarchiveObject(withFile: file) as? PersonyzeCondition
		{	self.name = myself.name
		}
		return self.name != nil
	}

	fileprivate func toStorage() throws
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Condition \(id).dat").path
		guard NSKeyedArchiver.archiveRootObject(self, toFile: file) else
		{	throw PersonyzeError.other("Couldn't save file: \(file)")
		}
	}

	//MARK: NSCoding

	public func encode(with aCoder: NSCoder)
	{	aCoder.encode(name, forKey: "name")
	}

	public required init?(coder aDecoder: NSCoder)
	{	 name = aDecoder.decodeObject(forKey: "name") as? String
	}
}

public class PersonyzePlaceholder : NSObject, NSCoding
{	public fileprivate(set) var id: Int = 0
	public fileprivate(set) var name: String? = nil
	public fileprivate(set) var htmlId: String? = nil
	public fileprivate(set) var unitsCountMax: Int = 0

	public init(id: Int)
	{	self.id = id
	}

	fileprivate func fromStorage() -> Bool
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Placeholder \(id).dat").path
		if let myself = NSKeyedUnarchiver.unarchiveObject(withFile: file) as? PersonyzePlaceholder
		{	self.name = myself.name
			self.htmlId = myself.htmlId
			self.unitsCountMax = myself.unitsCountMax
		}
		return self.name != nil
	}

	fileprivate func toStorage() throws
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Placeholder \(id).dat").path
		guard NSKeyedArchiver.archiveRootObject(self, toFile: file) else
		{	throw PersonyzeError.other("Couldn't save file: \(file)")
		}
	}

	//MARK: NSCoding

	public func encode(with aCoder: NSCoder)
	{	aCoder.encode(name, forKey: "name")
		aCoder.encode(htmlId, forKey: "htmlId")
		aCoder.encode(unitsCountMax, forKey: "unitsCountMax")
	}

	public required init?(coder aDecoder: NSCoder)
	{	name = aDecoder.decodeObject(forKey: "name") as? String
		htmlId = aDecoder.decodeObject(forKey: "htmlId") as? String
		unitsCountMax = aDecoder.decodeInteger(forKey: "unitsCountMax")
	}
}

public class PersonyzeActionClicked
{	var actionId: Int = 0
	var href: String = ""
	var status: String = ""
	var arg: String = ""
}

public class PersonyzeAction : NSObject, NSCoding
{	public fileprivate(set) var id: Int = 0
	public fileprivate(set) var name: String? = nil
	public fileprivate(set) var contentType: String? = nil
	fileprivate var contentParam: String? = nil
	fileprivate var contentBegin: String? = nil
	fileprivate var contentEnd: String? = nil
	fileprivate var libsApp: String? = nil
	fileprivate var cacheVersion: Int = 0
	fileprivate var placeholders: [PersonyzePlaceholder]? = nil
	fileprivate var data: Dictionary<String, String>? = nil

	public var content: String
	{	get
		{	return (contentBegin ?? "") + (data?[contentParam ?? ""] ?? "") + (contentEnd ?? "")
		}
	}

	public var contentJsonArray: [Dictionary<String, String>]?
	{	guard let contentType = contentType, contentType == "application/json" else
		{	return nil
		}
		if let data = content.data(using: .utf8)
		{	if let array = try? JSONDecoder().decode([Dictionary<String, CodableStringFromNum>].self, from: data)
			{	return array.map({ $0.mapValues({$0.value}) })
			}
		}
		return nil
	}

	public var contentHtmlDoc: String?
	{	get
		{	guard let contentType = contentType, contentType == "text/html" else
			{	return nil
			}
			var html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"></head><body style=\"visibility:hidden\" onload=\"document.body.style.visibility=''\"><script src=\""
			html += PersonyzeTracker.WEB_VIEW_LIB_URL
			html += "?v=\(cacheVersion)"
			html += "\"></script>"
			if let libsApp = libsApp
			{	for lib in libsApp.components(separatedBy: ",")
				{	let l = lib.trimmingCharacters(in: NSCharacterSet.whitespaces)
					if !l.isEmpty
					{	html += "<script src=\"\(PersonyzeTracker.LIBS_URL)\(lib).js?v=\(cacheVersion)\"></script>"
					}
				}
			}
			html += contentBegin ?? ""
			html += data?[contentParam ?? ""] ?? ""
			html += contentEnd ?? ""
			html += "<script>_S_T.new_elem(document.body, null)</script></body></html>"
			return html
		}
	}

	public init(id: Int)
	{	self.id = id
	}

	public init(id: Int, data: Dictionary<String, String>?, cacheVersion: Int)
	{	self.id = id
		self.data = data
		self.cacheVersion = cacheVersion
	}

	fileprivate func fromStorage() -> Bool
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Action \(id).dat").path
		if let myself = NSKeyedUnarchiver.unarchiveObject(withFile: file) as? PersonyzeAction
		{	self.placeholders = myself.placeholders
			if let placeholders = self.placeholders
			{	for item in placeholders
				{	if !item.fromStorage()
					{	return false
					}
				}
			}
			self.name = myself.name
			self.contentType = myself.contentType
			self.contentParam = myself.contentParam
			self.contentBegin = myself.contentBegin
			self.contentEnd = myself.contentEnd
			self.libsApp = myself.libsApp
			self.cacheVersion = myself.cacheVersion
		}
		return self.name != nil
	}

	fileprivate func toStorage() throws
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Action \(id).dat").path
		let d = data
		data = nil // i don't want it to be in the file
		guard NSKeyedArchiver.archiveRootObject(self, toFile: file) else
		{	data = d
			throw PersonyzeError.other("Couldn't save file: \(file)")
		}
		data = d
	}

	fileprivate func dataFromStorage()
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Action Data \(id).dat").path
		data = nil
		if let d = NSKeyedUnarchiver.unarchiveObject(withFile: file) as? Dictionary<String, String>
		{	data = d
		}
	}

	fileprivate func dataToStorage() throws
	{	let file = PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent("Personyze Action Data \(id).dat").path
		if let d = data
		{	guard NSKeyedArchiver.archiveRootObject(d, toFile: file) else
			{	throw PersonyzeError.other("Couldn't save file: \(file)")
			}
		}
		else
		{	try FileManager.default.removeItem(atPath: file)
		}
	}

	public func renderOnWebkitView(_ webView: WKWebView)
	{	renderOnWebkitView(webView, clickedCallback: nil)
	}

	public func renderOnWebkitView(_ webView: WKWebView, clickedCallback: ((PersonyzeActionClicked) -> Void)?)
	{	if let contentHtmlDoc = contentHtmlDoc
		{	webView.loadHTMLString(contentHtmlDoc, baseURL: URL(string: PersonyzeTracker.WEBVIEW_BASE_URL))
			class Handler : NSObject, WKScriptMessageHandler
			{	let actionId: Int
				let clickedCallback: ((PersonyzeActionClicked) -> Void)?

				init(actionId: Int, clickedCallback: ((PersonyzeActionClicked) -> Void)?)
				{	self.actionId = actionId
					self.clickedCallback = clickedCallback
				}

				func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
				{	if message.name == "personyze"
					{	if let body = message.body as? Dictionary<String, String>
						{	let clicked = PersonyzeActionClicked()
							clicked.actionId = actionId
							clicked.href = body["href"] ?? ""
							clicked.status = body["clicked"] ?? ""
							clicked.arg = body["arg"] ?? ""
							if let clickedCallback = clickedCallback
							{	clickedCallback(clicked)
							}
						}
					}
				}
			}
			webView.configuration.userContentController.removeScriptMessageHandler(forName: "personyze")
			webView.configuration.userContentController.add(Handler(actionId: id, clickedCallback: clickedCallback), name: "personyze")
			reportExecuted()
		}
	}

	public func reportExecuted()
	{	PersonyzeTracker.inst.reportActionStatus(actionId: id, status: "executed", arg: "")
	}

	public func reportClick()
	{	PersonyzeTracker.inst.reportActionStatus(actionId: id, status: "target", arg: "")
	}

	public func reportClose()
	{	PersonyzeTracker.inst.reportActionStatus(actionId: id, status: "close", arg: "0")
	}

	public func reportClose(dontShowSessions: Int)
	{	PersonyzeTracker.inst.reportActionStatus(actionId: id, status: "close", arg: "\(dontShowSessions < 0 ? 0 : dontShowSessions)")
	}

	public func reportProductClick(productId: String)
	{	if !productId.isEmpty
		{	PersonyzeTracker.inst.reportActionStatus(actionId: id, status: "product", arg: productId)
		}
	}

	public func reportArticleClick(articleId: String)
	{	if !articleId.isEmpty
		{	PersonyzeTracker.inst.reportActionStatus(actionId: id, status: "article", arg: articleId)
		}
	}

	public func reportError(message: String)
	{	PersonyzeTracker.inst.reportActionStatus(actionId: id, status: "error", arg: message)
	}

	//MARK: NSCoding

	public func encode(with aCoder: NSCoder)
	{	aCoder.encode(name, forKey: "name")
		aCoder.encode(contentType, forKey: "contentType")
		aCoder.encode(contentParam, forKey: "contentParam")
		aCoder.encode(contentBegin, forKey: "contentBegin")
		aCoder.encode(contentEnd, forKey: "contentEnd")
		aCoder.encode(libsApp, forKey: "libsApp")
		aCoder.encode(cacheVersion, forKey: "cacheVersion")
		aCoder.encode(placeholders?.map() {$0.id} ?? [], forKey: "placeholderIds")
	}

	public required init?(coder aDecoder: NSCoder)
	{	name = aDecoder.decodeObject(forKey: "name") as? String
		contentType = aDecoder.decodeObject(forKey: "contentType") as? String
		contentParam = aDecoder.decodeObject(forKey: "contentParam") as? String
		contentBegin = aDecoder.decodeObject(forKey: "contentBegin") as? String
		contentEnd = aDecoder.decodeObject(forKey: "contentEnd") as? String
		libsApp = aDecoder.decodeObject(forKey: "libsApp") as? String
		cacheVersion = aDecoder.decodeInteger(forKey: "cacheVersion")
		placeholders = []
		if let placeholderIds = aDecoder.decodeObject(forKey: "placeholderIds") as? [Int]
		{	for item in placeholderIds
			{	placeholders?.append(PersonyzePlaceholder(id: item))
			}
		}
	}
}

public struct PersonyzeResult
{	public var conditions: [PersonyzeCondition] = []
	public var actions: [PersonyzeAction] = []

	fileprivate mutating func fromStorage() -> Bool
	{	if let c = UserDefaults.standard.string(forKey: "Personyze Conditions")
		{	if let a = UserDefaults.standard.string(forKey: "Personyze Actions")
			{	conditions = c.isEmpty ? [] : c.components(separatedBy: ",").map
				{	PersonyzeCondition(id: Int($0) ?? 0)
				}
				actions = a.isEmpty ? [] : a.components(separatedBy: ",").map
				{	let a = PersonyzeAction(id: Int($0) ?? 0)
					a.dataFromStorage()
					return a
				}
				if
				(	conditions.reduce(true, {res, item in res && item.fromStorage()})
					&&
					actions.reduce(true, {res, item in res && item.fromStorage()})
				)
				{	return true
				}
				conditions = []
				actions = []
			}
		}
		return false
	}

	fileprivate func toStorage() throws
	{	let c = conditions.map({"\($0.id)"}).joined(separator: ",")
		let a = actions.map({"\($0.id)"}).joined(separator: ",")
		UserDefaults.standard.set(c, forKey: "Personyze Conditions")
		UserDefaults.standard.set(a, forKey: "Personyze Actions")
	}
}

public enum PersonyzeError : Error
{	case malformedApiKey(_: String)
	case requestTooBig(_: String)
	case http401(_: String)
	case http500(_: String)
	case http503(_: String)
	case other(_: String)

	public var localizedDescription: String
	{	get
		{	switch self
			{	case .malformedApiKey(let m): return m
				case .requestTooBig(let m): return m
				case .http401(let m): return m
				case .http500(let m): return m
				case .http503(let m): return m
				case .other(let m): return m
			}
		}
	}
}

fileprivate typealias AsyncResult<T> = (_: T?, _: PersonyzeError?) -> Void

fileprivate class AsyncResultSplit<T>
{	private var queue: [AsyncResult<T>] = []
	private var nTimes: Int
	private var n: Int = 0
	private var error: PersonyzeError? = nil

	init(_ nTimes: Int, _ asyncResult: AsyncResult<T>?)
	{	self.nTimes = nTimes
		add(asyncResult)
	}

	func add(_ asyncResult: AsyncResult<T>?)
	{	if let asyncResult = asyncResult
		{	queue.append(asyncResult)
		}
	}

	func success(_ result: T)
	{	n += 1
		if n == nTimes
		{	for q in queue
			{	q(error==nil ? result : nil, error)
			}
		}
	}

	func error(_ error: PersonyzeError)
	{	self.error = error
		n += 1
		if n == nTimes
		{	for q in queue
			{	q(nil, error)
			}
			if queue.count == 0
			{	os_log("Personyze error: %s", type: .error, error.localizedDescription)
			}
		}
	}
}

fileprivate struct CodableIntFromString : Codable
{	var value: Int

	init(from decoder: Decoder) throws
	{	let container = try decoder.singleValueContainer()
		let asInt = try? container.decode(Int.self)
		value = try asInt ?? Int(container.decode(String.self)) ?? 0
	}
}

fileprivate struct CodableStringFromNum : Codable
{	var value: String

	init(from decoder: Decoder) throws
	{	let container = try decoder.singleValueContainer()
		if let v = try? container.decode(String.self)
		{	value = v
		}
		else if let v = try? container.decode(Int64.self)
		{	value = "\(v)"
		}
		else if let v = try? container.decode(Double.self)
		{	value = "\(v)"
		}
		else
		{	value = ""
		}
	}
}

fileprivate struct StoredIntMap
{	private let forKey: String
	private var data: Dictionary<Int, Int> = [:]

	init(forKey: String)
	{	self.forKey = forKey
		if let str = UserDefaults.standard.string(forKey: forKey)
		{	for kv in str.components(separatedBy: ",").map({$0.components(separatedBy: ":")})
			{	if kv.count == 2
				{	let k = Int(kv[0]) ?? 0
					let v = Int(kv[1]) ?? 0
					if k > 0 && v > 0
					{	data[k] = v
					}
				}
			}
		}
	}

	func save()
	{	let str = data.map({k, v in "\(k):\(v)"}).joined(separator: ",")
		UserDefaults.standard.set(str, forKey: forKey)
	}

	subscript(k: Int) -> Int?
	{	get
		{	return data[k]
		}
		set(v)
		{	data[k] = v
		}
	}

	mutating func dec()
	{	for (k, v) in data
		{	data[k] = v - 1
		}
		data = data.filter {$0.1 > 0}
		save()
	}
}

fileprivate struct PastSessions
{	var value = UserDefaults.standard.string(forKey: "Personyze Past Sessions") ?? ""

	mutating func add(_ sessionStartTime: Int)
	{	// add
		if value.isEmpty
		{	value = "\(sessionStartTime)"
		}
		else if value.split(separator: ",").count+1 <= PersonyzeTracker.REMEMBER_PAST_SESSIONS
		{	value += ",\(sessionStartTime)"
		}
		else
		{	value = value[value.index(after: value.index(of: ",")!)...] + ",\(sessionStartTime)"
		}
		// save
		UserDefaults.standard.set(value, forKey: "Personyze Past Sessions")
	}
}

fileprivate func synchronized(_ lock: AnyObject, block: () throws -> Void) rethrows
{	objc_sync_enter(lock)
	defer
	{	objc_sync_exit(lock)
	}
	try block()
}

fileprivate func getSessionStartTime(_ sessionId: String?) -> Int
{	// sessionId contains information that Personyze server wants me to store and send him back. The only thing he promises me is that there is sessionStartTime in the beginning
	let tm = sessionId?.components(separatedBy: CharacterSet.decimalDigits.inverted).first
	if let tm = tm
	{	return Int(tm) ?? 0
	}
	return 0
}

public class PersonyzeTracker
{	private static let GATEWAY_URL = "https://app.personyze.com/rest/"
	fileprivate static let WEB_VIEW_LIB_URL = "https://counter.personyze.com/web-view.js"
	fileprivate static let LIBS_URL = "https://counter.personyze.com/actions/webkit/"
	fileprivate static let WEBVIEW_BASE_URL = "https://counter.personyze.com/"
	private static let USER_AGENT = "Personyze iOS SDK/1.0"
	private static let POST_LIMIT = 50000
	fileprivate static let REMEMBER_PAST_SESSIONS = 2
	fileprivate static let STORAGE_DIRECTORY = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!

	private var isInitialized = false
	private var apiKey: String? = nil
	private var httpAuth: String? = nil
	private var userId: Int = 0
	private let urlSession = URLSession.shared
	private var commands: [[String]] = []
	private var isNavigate = false
	private var wantNewSession: Bool = false
	private var sessionId: String? = nil
	private var cacheVersion: Int = 0
	private var apiKeyHash: Int = 0
	private var trackerResult: PersonyzeResult? = nil
	private var queryingResults: AsyncResultSplit<PersonyzeResult>? = nil
	private var blockedActions = StoredIntMap(forKey: "Personyze Blocked Actions")
	private var pastSessions = PastSessions()

	// Singleton
	public static let inst = PersonyzeTracker()
	private init() {}

	private func httpFetch(path: String, postData: Data?, asyncResult: @escaping AsyncResult<Data>)
	{	var request = URLRequest(url: URL(string: PersonyzeTracker.GATEWAY_URL+path)!)
		request.httpMethod = postData==nil ? "GET" : "POST"
		request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
		request.setValue(PersonyzeTracker.USER_AGENT, forHTTPHeaderField: "User-Agent")
		request.setValue(httpAuth, forHTTPHeaderField: "Authorization")
		request.httpBody = postData

		urlSession.dataTask(with: request)
		{	data, response, error in
			DispatchQueue.main.async
			{	guard let res = response as? HTTPURLResponse, res.statusCode==200 || res.statusCode==500 || res.statusCode==503 || res.statusCode==401, let data = data else
				{	return asyncResult(nil, .other("HTTP request failed: "+(error?.localizedDescription ?? "unspecified error")))
				}
				guard res.statusCode != 503 else
				{	return asyncResult(nil, .http503("Service temporarily unavailable"))
				}
				guard res.statusCode != 401 else
				{	return asyncResult(nil, .http401("Invalid API key"))
				}
				guard res.statusCode == 200, data.count != 0 else
				{	let message = String(data: data, encoding: .utf8)
					return asyncResult(nil, .http500(message ?? "Server error"))
				}
				asyncResult(data, nil)
			}
		}.resume()
	}

	private func flush(requireSomeResult: Bool, isStartNewSession: Bool, asyncResult: AsyncResult<PersonyzeResult>?)
	{	var returnError: PersonyzeError? = nil
		var returnPersonyzeResult: PersonyzeResult? = nil
		synchronized(self)
		{	do
			{	try doInitialize()
				if commands.count>0 || requireSomeResult && trackerResult==nil
				{	// Form the POST request that includes session data and commands
					struct PostJson : Codable
					{	let user_id: Int
						let session_id: String?
						let new_session: Bool
						let past_sessions: String
						let platform: String
						let time_zone: Double
						let languages: String
						let screen: String
						let os: String
						let device_type: String
						let commands: [[String]]
					}
					let postJson = PostJson(
						user_id: userId,
						session_id: sessionId,
						new_session: wantNewSession || sessionId == nil || Double(getSessionStartTime(sessionId!)+90*60-5) <= Date().timeIntervalSince1970,
						past_sessions: pastSessions.value,
						platform: UIDevice.current.systemName,
						time_zone: Double(TimeZone.current.secondsFromGMT() / (60*60)),
						languages: Locale.preferredLanguages.joined(separator: ","),
						screen: "\(UIScreen.main.bounds.size.width)x\(UIScreen.main.bounds.size.height)",
						os: "\(UIDevice.current.systemName)/\(UIDevice.current.systemVersion)",
						device_type: UIDevice.current.userInterfaceIdiom == .phone ? "phone" : UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "regular",
						commands: commands
					)
					let postData = try JSONEncoder().encode(postJson)
					commands.removeAll() // delete commands that are about to be sent (to avoid sending twice)
					if postData.count > PersonyzeTracker.POST_LIMIT
					{	returnError = .requestTooBig("Request was too big")
					}
					else
					{	let curIsNavigate = isNavigate
						isNavigate = false
						// Further getResult() must use new object
						let asyncResults = AsyncResultSplit(1, asyncResult)
						queryingResults = asyncResults
						wantNewSession = false
						// Send the request
						httpFetch(path: "tracker-v1", postData: postData)
						{	success, error in
							if let error = error
							{	self.queryingResults = nil
								asyncResults.error(error)
							}
							else
							{	struct ResponseCondition : Codable
								{	var id: CodableIntFromString
								}
								struct ResponseAction : Codable
								{	var id: CodableIntFromString
									var data: Dictionary<String, String>?
								}
								struct Response : Codable
								{	var session_id: String?
									var cache_version: Int
									var conditions: [ResponseCondition]
									var actions: [ResponseAction]
									var dismiss_conditions: [CodableIntFromString]
									var dismiss_actions: [CodableIntFromString]
								}
								do
								{	var response = try JSONDecoder().decode(Response.self, from: success!)
									// vars
									var wantClearCache = false
									var loadConditions = false
									var loadActions = false
									var newTrackerResult = PersonyzeResult()
									var hasCommandsAdded = false
									try synchronized(self)
									{	if response.session_id == nil
										{	response.session_id = self.sessionId
										}
										if response.cache_version == 0
										{	response.cache_version = self.cacheVersion
										}
										wantClearCache = response.cache_version > self.cacheVersion
										self.cacheVersion = response.cache_version
										let rSessionStartTime = getSessionStartTime(response.session_id)
										let isNewSession = rSessionStartTime != getSessionStartTime(self.sessionId)
										self.sessionId = response.session_id
										if isNewSession
										{	self.blockedActions.dec()
											self.pastSessions.add(rSessionStartTime)
										}
										if wantClearCache
										{	try self.clearCache()
										}
										if isNewSession
										{	UserDefaults.standard.set(response.session_id, forKey: "Personyze User")
											UserDefaults.standard.removeObject(forKey: "Personyze New Session")
										}
										// newTrackerResult.conditions
										newTrackerResult.conditions = response.conditions.map({PersonyzeCondition(id: $0.id.value)})
										if !wantClearCache
										{	loadConditions = newTrackerResult.conditions.reduce(false, {res, item in !item.fromStorage() || res})
										}
										// newTrackerResult.actions
										newTrackerResult.actions.reserveCapacity(response.actions.count)
										for item in response.actions
										{	if self.blockedActions[item.id.value] == nil
											{	let action = PersonyzeAction(id: item.id.value, data: item.data, cacheVersion: self.cacheVersion)
												if !wantClearCache && !action.fromStorage()
												{	loadActions = true
												}
												newTrackerResult.actions.append(action)
												// store data, so it will survive application restart
												try? action.dataToStorage()
											}
											else
											{	self.commands.append(["Action Status", "\(item.id.value)", "dont-show"])
												hasCommandsAdded = true
											}
										}
									}
									// done
									self.loadWhatNeededThenSetResult(
										newTrackerResult: newTrackerResult,
										curIsNavigate: curIsNavigate,
										dismissConditions: response.dismiss_conditions,
										dismissActions: response.dismiss_actions,
										loadConditions: loadConditions || wantClearCache && newTrackerResult.conditions.count>0,
										loadActions: loadActions || wantClearCache && newTrackerResult.actions.count>0,
										noTryCache: wantClearCache,
										asyncResults: asyncResults
									)
									if hasCommandsAdded
									{  self.flush(requireSomeResult: false, isStartNewSession: false, asyncResult: nil)
									}
								}
								catch
								{	self.queryingResults = nil
									asyncResults.error(.other(error.localizedDescription))
								}
							}
						}
					}
				}
				else if let asyncResult = asyncResult
				{	// Nothing to send, just get current result
					if let q = queryingResults
					{	q.add(asyncResult)
					}
					else
					{	returnPersonyzeResult = trackerResult ?? PersonyzeResult()
					}
				}
			}
			catch
			{	if let trackerError = error as? PersonyzeError
				{	returnError = trackerError
				}
				else
				{	commands.removeAll() // discard failed commands
					isNavigate = false
					returnError = .other("Couldn't JSON encode: \(error.localizedDescription)")
				}
			}
			if isStartNewSession
			{	wantNewSession = true
				trackerResult = nil
				UserDefaults.standard.set(true, forKey: "Personyze New Session")
				UserDefaults.standard.removeObject(forKey: "Personyze Conditions")
				UserDefaults.standard.removeObject(forKey: "Personyze Actions")
			}
		}
		// now not synchronized
		if let returnError = returnError
		{	if let asyncResult = asyncResult
			{	asyncResult(nil, returnError)
			}
			else
			{	os_log("Personyze error: %s", type: .error, returnError.localizedDescription)
			}
		}
		else if let returnPersonyzeResult = returnPersonyzeResult
		{	asyncResult?(returnPersonyzeResult, nil)
		}
	}

	private func setResult(_ newTrackerResult: PersonyzeResult, curIsNavigate: Bool, dismissConditions: [CodableIntFromString], dismissActions: [CodableIntFromString])
	{	if curIsNavigate || trackerResult==nil
		{	trackerResult = newTrackerResult
		}
		else
		{	// merge with new result
			for c in newTrackerResult.conditions
			{	if trackerResult?.conditions.index(where: {$0.id == c.id}) == nil
				{	trackerResult?.conditions.append(c)
				}
			}
			for a in newTrackerResult.actions
			{	if trackerResult?.actions.index(where: {$0.id == a.id}) == nil
				{	trackerResult?.actions.append(a)
				}
			}
			for c in dismissConditions
			{	if let pos = trackerResult?.conditions.index(where: {$0.id == c.value})
				{	trackerResult?.conditions.remove(at: pos)
				}
			}
			for a in dismissActions
			{	if let pos = trackerResult?.actions.index(where: {$0.id == a.value})
				{	trackerResult?.actions.remove(at: pos)
				}
			}
		}
		do
		{	try trackerResult?.toStorage()
		}
		catch
		{	os_log("Personyze error: %s", type: .error, error.localizedDescription)
		}
	}

	private func loadWhatNeededThenSetResult(newTrackerResult: PersonyzeResult, curIsNavigate: Bool, dismissConditions: [CodableIntFromString], dismissActions: [CodableIntFromString], loadConditions: Bool, loadActions: Bool, noTryCache: Bool, asyncResults: AsyncResultSplit<PersonyzeResult>)
	{	if !loadConditions && !loadActions
		{	// done
			var returnPersonyzeResult: PersonyzeResult? = nil
			synchronized(self)
			{	setResult(newTrackerResult, curIsNavigate: curIsNavigate, dismissConditions: dismissConditions, dismissActions: dismissActions)
				queryingResults = nil
				returnPersonyzeResult = trackerResult
			}
			asyncResults.success(returnPersonyzeResult!)
		}
		else
		{	// need to load conditions/actions
			let asyncResultSplit = AsyncResultSplit<Void>(loadConditions && loadActions ? 2 : 1)
			{	result, error in
				if let error = error
				{	synchronized(self)
					{	self.queryingResults = nil
					}
					asyncResults.error(error)
				}
				else
				{	var returnPersonyzeResult: PersonyzeResult? = nil
					synchronized(self)
					{	self.setResult(newTrackerResult, curIsNavigate: curIsNavigate, dismissConditions: dismissConditions, dismissActions: dismissActions)
						self.queryingResults = nil
						returnPersonyzeResult = self.trackerResult
					}
					asyncResults.success(returnPersonyzeResult!)
				}
			}
			if loadConditions
			{	let ids = newTrackerResult.conditions.filter({noTryCache || $0.name == nil}).map({"\($0.id)"}).joined(separator: ",")
				httpFetch(path: "conditions/columns/id,name/where/id:\(ids)", postData: nil)
				{	success, error in
					if let error = error
					{	asyncResultSplit.error(error)
					}
					else
					{	struct Response : Codable
						{	var id: CodableIntFromString
							var name: String
						}
						do
						{	let response = try JSONDecoder().decode([Response].self, from: success!)
							for item in response
							{	for condition in newTrackerResult.conditions
								{	if condition.id == item.id.value
									{	condition.name = item.name
										try condition.toStorage()
										break
									}
								}
							}
							asyncResultSplit.success(())
						}
						catch
						{	asyncResultSplit.error(.other(error.localizedDescription))
						}
					}
				}
			}
			if loadActions
			{	let ids = newTrackerResult.actions.filter({noTryCache || $0.name == nil}).map({"\($0.id)"}).joined(separator: ",")
				httpFetch(path: "actions/columns/id,name,content_type,content_param,content_begin,content_end,libs_app,placeholders/where/id:\(ids)", postData: nil)
				{	success, error in
					if let error = error
					{	asyncResultSplit.error(error)
					}
					else
					{	struct Response : Codable
						{	var id: CodableIntFromString
							var name: String
							var content_type: String
							var content_param: String
							var content_begin: String
							var content_end: String
							var libs_app: String
							var placeholders: [CodableIntFromString]
						}
						do
						{	var loadPlaceholders: String? = nil
							let response = try JSONDecoder().decode([Response].self, from: success!)
							for item in response
							{	for action in newTrackerResult.actions
								{	if action.id == item.id.value
									{	action.name = item.name
										action.contentType = item.content_type
										action.contentParam = item.content_param
										action.contentBegin = item.content_begin
										action.contentEnd = item.content_end
										action.libsApp = item.libs_app
										action.placeholders = []
										action.placeholders?.reserveCapacity(item.placeholders.count)
										for item_p in item.placeholders
										{	let placeholder = PersonyzePlaceholder(id: item_p.value)
											if !noTryCache && !placeholder.fromStorage()
											{	if var loadPlaceholders = loadPlaceholders
												{	loadPlaceholders.append(",")
													loadPlaceholders.append("\(placeholder.id)")
												}
												else
												{	loadPlaceholders = "placeholders/columns/id,name,html_id,units_count_max/where/id:"
													loadPlaceholders!.append("\(placeholder.id)")
												}
											}
											action.placeholders!.append(placeholder)
										}
										try action.toStorage()
										break
									}
								}
							}
							if let loadPlaceholders = loadPlaceholders
							{	self.httpFetch(path: loadPlaceholders, postData: nil)
								{	success, error in
									if let error = error
									{	asyncResultSplit.error(error)
									}
									else
									{	struct Response : Codable
										{	var id: CodableIntFromString
											var name: String
											var html_id: String
											var units_count_max: CodableIntFromString
										}
										do
										{	let response = try JSONDecoder().decode([Response].self, from: success!)
											for item in response
											{	for action in newTrackerResult.actions
												{	if let placeholders = action.placeholders
													{	for placeholder in placeholders
														{	if placeholder.id == item.id.value
															{	placeholder.name = item.name
																placeholder.htmlId = item.html_id
																placeholder.unitsCountMax = item.units_count_max.value
																try placeholder.toStorage()
																break
															}
														}
													}
												}
											}
											asyncResultSplit.success(())
										}
										catch
										{	asyncResultSplit.error(.other(error.localizedDescription))
										}
									}
								}
							}
							else
							{	asyncResultSplit.success(())
							}
						}
						catch
						{	asyncResultSplit.error(.other(error.localizedDescription))
						}
					}
				}
			}
		}
	}

	/**
	* Send Action Status to Personyze. When you show executed actions, you can report that user clicked on a click target (button), or closed that action.
	* @param actionId The action ID. Get it from PersonyzeAction object, from "id" property.
	* @param status One of: "target", "close", "product", "article" or "error". 1. "target" means user clicked the destination button. In this case "arg" will be ignored. 2. "close" - user chosen to dismiss this action. "arg" is number of sessions not to show again. 3. "product" - user clicked on a product in a recommendation widget. "arg" is product internal ID. 4. "article" is like "product". 5. "error" - you rejected to show this action to user. "arg" is reason message (will appear in visits dashboard).
	* @param arg See "status".
	*/
	func reportActionStatus(actionId: Int, status: String, arg: String)
	{	if actionId > 0 && !status.isEmpty
		{	synchronized(self)
			{	let actionIdStr = "\(actionId)"
				// Already?
				for command in commands.reversed()
				{	if command.count==2 && command[0]=="Navigate"
					{	break
					}
					if command.count==4 && command[1]==actionIdStr && command[0]=="Action Status"
					{	if status=="executed" || status==command[2]
						{	return // yes, already reported
						}
					}
				}
				// Report
				commands.append(["Action Status", actionIdStr, status, arg])
				if status == "close"
				{	if let nSessions = Int(arg)
					{	if nSessions > 0
						{	blockedActions[actionId] = nSessions
							blockedActions.save()
						}
					}
				}
			}
			flush(requireSomeResult: false, isStartNewSession: false, asyncResult: nil)
		}
	}

	private func doInitialize() throws
	{	if !isInitialized
		{	guard let apiKey = apiKey, apiKey.count == 40 else
			{	throw PersonyzeError.malformedApiKey("API key must be 40 characters")
			}
			guard let auth = "api:\(apiKey)".data(using: .utf8)?.base64EncodedString() else
			{	throw PersonyzeError.malformedApiKey("Malformed API key")
			}
			httpAuth = "Basic \(auth)"
			guard let userId = UIDevice.current.identifierForVendor?.hashValue else
			{	throw PersonyzeError.other("Couldn't get Vendor Id")
			}
			self.userId = userId
			apiKeyHash = apiKey.hashValue
			trackerResult = nil
			isInitialized = true
			// restore current state
			wantNewSession = UserDefaults.standard.bool(forKey: "Personyze New Session")
			sessionId = UserDefaults.standard.string(forKey: "Personyze User")
			cacheVersion = UserDefaults.standard.integer(forKey: "Personyze Cache Version")
			if UserDefaults.standard.integer(forKey: "Api Key Hash") != apiKeyHash
			{	try? clearCache() // delete cached conditions and actions from (possibly) different account
				UserDefaults.standard.set(apiKeyHash, forKey: "Api Key Hash")
			}
			var res = PersonyzeResult()
			if res.fromStorage()
			{	trackerResult = res
			}
		}
	}

	// MARK: public

	/**
	* Initialize the tracker. This is required before calling any other methods. Typically you need to call this once. Second call with the same apiKey will do nothing.
	* @param apiKey Your personal secret key obtained in the Personyze account.
	*/
	public func initialize(apiKey: String)
	{	synchronized(self)
		{	if self.apiKey==nil || self.apiKey != apiKey
			{	self.isInitialized = false
				self.apiKey = apiKey
			}
		}
	}

	/**
	* Send navigation event to Personyze. This is equivalent to a page view on your site.
	* @param documentName Document identifier, that represents navigation within your app. You can use any name, e.g. "Cart page".
	*/
	public func navigate(documentName: String)
	{	if !documentName.isEmpty
		{	synchronized(self)
			{	commands.append(["Navigate", "urn:personyze:doc:\(documentName)"])
				isNavigate = true
			}
		}
	}

	/**
	* Send user profile data to Personyze, like email.
	* @param key Profile field. Can be any identifier.
	* @param value The value you want to send.
	*/
	public func logUserData(field: String, value: String)
	{	if !field.isEmpty
		{	synchronized(self)
			{	commands.append(["User profile", field, value])
			}
		}
	}

	/**
	* Send "Product Viewed" event to Personyze.
	* @param productId The product ID is what appears in your products catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FProducts%20catalog" target="_blank">here</a>.
	*/
	public func productViewed(productId: String)
	{	if !productId.isEmpty
		{	synchronized(self)
			{	commands.append(["Product Viewed", productId])
			}
		}
	}

	/**
	* Send "Product Added to cart" event to Personyze.
	* @param productId The product ID is what appears in your products catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FProducts%20catalog" target="_blank">here</a>.
	*/
	public func productAddedToCart(productId: String)
	{	if !productId.isEmpty
		{	synchronized(self)
			{	commands.append(["Product Added to cart", productId])
			}
		}
	}

	/**
	* Send "Product Liked" ("Added to favorites") event to Personyze.
	* @param productId The product ID is what appears in your products catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FProducts%20catalog" target="_blank">here</a>.
	*/
	public func productLiked(productId: String)
	{	if !productId.isEmpty
		{	synchronized(self)
			{	commands.append(["Product Liked", productId])
			}
		}
	}

	/**
	* Send "Product Purchased" event to Personyze.
	* @param productId The product ID is what appears in your products catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FProducts%20catalog" target="_blank">here</a>.
	*/
	public func productPurchased(productId: String)
	{	if !productId.isEmpty
		{	synchronized(self)
			{	commands.append(["Product Purchased", productId])
			}
		}
	}

	/**
	* Send "Product Unliked" ("Removed from favorites") event to Personyze.
	* @param productId The product ID is what appears in your products catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FProducts%20catalog" target="_blank">here</a>.
	*/
	public func productUnliked(productId: String)
	{	if !productId.isEmpty
		{	synchronized(self)
			{	commands.append(["Product Unliked", productId])
			}
		}
	}

	/**
	* Send "Product Removed from cart" event to Personyze.
	* @param productId The product ID is what appears in your products catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FProducts%20catalog" target="_blank">here</a>.
	*/
	public func productRemovedFromCart(productId: String)
	{	if !productId.isEmpty
		{	synchronized(self)
			{	commands.append(["Product Removed from cart", productId])
			}
		}
	}

	/**
	* Send "Products Purchased" event to Personyze. This event converts all the products that were Added to cart to Purchased.
	*/
	public func productsPurchased()
	{	synchronized(self)
		{	commands.append(["Products Purchased"])
		}
	}

	/**
	* Send "Products Unliked" event to Personyze. This event converts all the products that were Liked to Viewed.
	*/
	public func productsUnliked()
	{	synchronized(self)
		{	commands.append(["Products Unliked"])
		}
	}

	/**
	* Send "Products Removed from cart" event to Personyze. This event converts all the products that were Added to cart to Viewed.
	*/
	public func productsRemovedFromCart()
	{	synchronized(self)
		{	commands.append(["Products Removed from cart"])
		}
	}

	/**
	* Send "Article Viewed" event to Personyze.
	* @param productId The article ID is what appears in your articles catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FArticles%20catalog" target="_blank">here</a>.
	*/
	public func articleViewed(articleId: String)
	{	if !articleId.isEmpty
		{	synchronized(self)
			{	commands.append(["Article Viewed", articleId])
			}
		}
	}

	/**
	* Send "Article Liked" (added to favorites) event to Personyze.
	* @param productId The article ID is what appears in your articles catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FArticles%20catalog" target="_blank">here</a>.
	*/
	public func articleLiked(articleId: String)
	{	if !articleId.isEmpty
		{	synchronized(self)
			{	commands.append(["Article Liked", articleId])
			}
		}
	}

	/**
	* Send "Article Commented" event to Personyze.
	* @param productId The article ID is what appears in your articles catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FArticles%20catalog" target="_blank">here</a>.
	*/
	public func articleCommented(articleId: String)
	{	if !articleId.isEmpty
		{	synchronized(self)
			{	commands.append(["Article Commented", articleId])
			}
		}
	}

	/**
	* Send "Article Unliked" (removed from favorites) event to Personyze.
	* @param productId The article ID is what appears in your articles catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FArticles%20catalog" target="_blank">here</a>.
	*/
	public func articleUnliked(articleId: String)
	{	if !articleId.isEmpty
		{	synchronized(self)
			{	commands.append(["Article Unliked", articleId])
			}
		}
	}

	/**
	* Send "Article Reached Goal" event to Personyze.
	* @param productId The article ID is what appears in your articles catalog uploaded to Personyze, in the "Internal ID" column.
	*                  You can see your catalog <a href="https://personyze.com/site/tracker/condition/index#cat=Account%20settings%2FRecommendations%2FArticles%20catalog" target="_blank">here</a>.
	*/
	public func articleGoal(articleId: String)
	{	if !articleId.isEmpty
		{	synchronized(self)
			{	commands.append(["Article Goal", articleId])
			}
		}
	}

	/**
	* When you call action.renderOnWebView(), it generates click events when user taps goal/close buttons in action HTML. If your application processes that events (e.g. closes action), you need to report this to Personyze, so you will have CTR and close-rate statistics.
	* @param clicked Object that action.renderOnWebView() gives you.
	*/
	public func reportActionClicked(clicked: PersonyzeActionClicked)
	{	reportActionStatus(actionId: clicked.actionId, status: clicked.status, arg: clicked.arg)
	}

	/**
	* What conditions are matching, and what actions are to be presented. This will send pending events to Personyze. This library remembers (stores to memory) the result, and until you call startNewSession(), you can get current result, even after object recreation.
	* @param asyncResult Callback.
	*/
	public func getResult(asyncResult: @escaping (_: PersonyzeResult?, _: PersonyzeError?) -> Void)
	{	flush(requireSomeResult: true, isStartNewSession: false, asyncResult: asyncResult)
	}

	/**
	* This asks Personyze to start new session for current user. For each user Personyze counts number of sessions.
	* Call this when user closes and reopens the application. Each session lasts not more than 1.5 hours, so it will
	* restart after this period automatically.
	*/
	public func startNewSession()
	{	flush(requireSomeResult: false, isStartNewSession: true, asyncResult: nil)
	}

	/**
	* Call this at last. This method sends pending events to Personyze.
	*/
	public func done()
	{	flush(requireSomeResult: false, isStartNewSession: false, asyncResult: nil)
	}

	/**
	* Normally, you don't need to call this.
	*/
	public func clearCache() throws
	{	for item in try FileManager.default.contentsOfDirectory(atPath: PersonyzeTracker.STORAGE_DIRECTORY.path).filter() {$0.hasPrefix("Personyze ")}
		{	try FileManager.default.removeItem(atPath: PersonyzeTracker.STORAGE_DIRECTORY.appendingPathComponent(item).path)
		}
	}
}
