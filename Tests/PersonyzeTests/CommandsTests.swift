import Testing
@testable import Personyze

struct CommandsTests
{	@Test func navigateEncodesLikeEncodeURIComponent() throws
	{	#expect(try Commands.navigate("MainActivity") == ["Navigate", "urn:personyze:doc:MainActivity"])
		#expect(try Commands.navigate("Cart page") == ["Navigate", "urn:personyze:doc:Cart%20page"])
		#expect(try Commands.navigate("100% off/now?")[1] == "urn:personyze:doc:100%25%20off%2Fnow%3F")
		#expect(try Commands.navigate("a-_.!~*'()b")[1] == "urn:personyze:doc:a-_.!~*'()b")
		#expect(try Commands.navigate("שלום")[1] == "urn:personyze:doc:%D7%A9%D7%9C%D7%95%D7%9D")
		#expect(throws: PersonyzeError.self)
		{	try Commands.navigate(" ")
		}
	}

	@Test func productsCarryAttributionPairs() throws
	{	#expect(try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) == ["Product Viewed", "A1"])
		#expect(try Commands.product("Product Purchased", "A1", actionId: 88, quantity: 2) == ["Product Purchased", "A1", "action_id", "88", "quantity", "2"])
		#expect(try Commands.product("Product Added to cart", "A1", actionId: nil, quantity: 3) == ["Product Added to cart", "A1", "quantity", "3"])
		#expect(throws: PersonyzeError.self)
		{	try Commands.product("Product Viewed", "", actionId: nil, quantity: nil)
		}
		#expect(throws: PersonyzeError.self)
		{	try Commands.product("Product Viewed", "A1", actionId: 0, quantity: nil)
		}
		#expect(throws: PersonyzeError.self)
		{	try Commands.product("Product Viewed", "A1", actionId: nil, quantity: 0)
		}
	}

	@Test func articlesAndBareCommands() throws
	{	#expect(try Commands.article("Article Goal", "B2", actionId: 9) == ["Article Goal", "B2", "action_id", "9"])
		#expect(Commands.bare("Products Removed from cart") == ["Products Removed from cart"])
		#expect(throws: PersonyzeError.self)
		{	try Commands.article("Article Viewed", " ", actionId: nil)
		}
	}

	@Test func promotionsNeedTheirActionId() throws
	{	#expect(try Commands.promotion("promotion viewed", " SPRING-HERO ", actionId: 77) == ["promotion viewed", "SPRING-HERO", "action_id", "77"])
		#expect(throws: PersonyzeError.self)
		{	try Commands.promotion("promotion clicked", "X", actionId: 0)
		}
		#expect(try Commands.coupon("WELCOME10") == ["coupon used", "WELCOME10"])
		#expect(throws: PersonyzeError.self)
		{	try Commands.coupon("")
		}
	}

	@Test func profileIsOneCommandOfPairs() throws
	{	#expect(try Commands.profile([("email", "a@b.c"), ("gender", nil)]) == ["User profile", "email", "a@b.c", "gender", nil])
		#expect(throws: PersonyzeError.self)
		{	try Commands.profile([])
		}
		#expect(throws: PersonyzeError.self)
		{	try Commands.profile([("", "x")])
		}
	}

	@Test func actionStatusIsFourStrings() throws
	{	#expect(try Commands.actionStatus(88, "executed") == ["Action Status", "88", "executed", ""])
		#expect(try Commands.actionStatus(88, "close", "3") == ["Action Status", "88", "close", "3"])
		#expect(throws: PersonyzeError.self)
		{	try Commands.actionStatus(0, "executed")
		}
		#expect(throws: PersonyzeError.self)
		{	try Commands.actionStatus(1, "clicked")
		}
	}

	@Test func refusalSaysWhy()
	{	#expect(throws: PersonyzeError.invalid(message: "Personyze: unknown action status 'clicked'"))
		{	try Commands.actionStatus(1, "clicked")
		}
	}

	@Test func oversizedCommandIsRefused()
	{	#expect(throws: PersonyzeError.self)
		{	try Commands.raw(["x", String(repeating: "y", count: Commands.maxCommand)])
		}
		#expect(throws: PersonyzeError.self)
		{	try Commands.raw([" "])
		}
	}

	@Test func recognizesNavigateAndActionStatus() throws
	{	#expect(Commands.isNavigate(try Commands.navigate("Home")))
		#expect(Commands.isNavigate(["navigate", "x"]))
		#expect(!Commands.isNavigate(["Navigate"]))
		#expect(Commands.isActionStatus(try Commands.actionStatus(5, "target")))
	}

	/// By the visitor id alone: nothing to encode (1.x's session string was encoded for a parser that
	/// no longer exists, and answered 400).
	@Test func notificationPathNamesTheVisitor()
	{	#expect(Endpoints.notification(42, messageId: 5) == "current_notification/where/user_id=42&message_id=5")
		#expect(Endpoints.notification(-7) == "current_notification/where/user_id=-7")
	}

	@Test func metadataPaths()
	{	#expect(Endpoints.conditions([1, 2]) == "conditions/columns/id,name/where/id:1,2")
		#expect(Endpoints.actions([88], withOrder: true) == "actions/columns/id,name,content_type,content_param,content_begin,content_end,libs_app,placeholders,placeholder_order/where/id:88")
		#expect(Endpoints.actions([88], withOrder: false) == "actions/columns/id,name,content_type,content_param,content_begin,content_end,libs_app,placeholders/where/id:88")
		#expect(Endpoints.placeholders([635]) == "placeholders/columns/id,name,html_id,units_count_max/where/id:635")
		#expect(Endpoints.verdict(273) == "ab_test/where/condition_id=273")
	}
}
