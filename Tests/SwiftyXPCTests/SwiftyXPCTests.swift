import XCTest

@testable import SwiftyXPC
import System
import TestShared

// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
final class SwiftyXPCTests: XCTestCase {
    var helperLauncher: HelperLauncher?

    override func setUp() async throws {
        self.helperLauncher = try HelperLauncher()
        try self.helperLauncher?.startHelper()
    }

    override func tearDown() async throws {
        try self.helperLauncher?.stopHelper()
    }

    func testProcessIDs() async throws {
        let conn = try await self.openConnection()

        let ids: ProcessIDs = try await conn.sendMessage(name: CommandSet.reportIDs)

        XCTAssertEqual(ids.pid, conn.processIdentifier)
        XCTAssertEqual(ids.effectiveUID, conn.effectiveUserIdentifier)
        XCTAssertEqual(ids.effectiveGID, conn.effectiveGroupIdentifier)
        XCTAssertEqual(ids.auditSessionID, conn.auditSessionIdentifier)
    }

    func testCodeSignatureVerification() async throws {
        let goodConn = try await self.openConnection(codeSigningRequirement: self.helperLauncher!.codeSigningRequirement)

        let response: String = try await goodConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        XCTAssertEqual(response, "TESTING 1 2 3")

        let failsSignatureVerification = self.expectation(
            description: "Fails to send message because of code signature mismatch"
        )

        do {
            let badConn = try await self.openConnection(codeSigningRequirement: "identifier \"com.apple.true\" and anchor apple")
            try await badConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        } catch let error as XPCError {
            if case .unknown(let errorDesc) = error, errorDesc == "Peer Forbidden" {
                failsSignatureVerification.fulfill()
            } else {
                throw error
            }
        }

        let failsConnectionInitialization = self.expectation(
            description: "Fails to initialize connection because of bad code signing requirement"
        )

        do {
            _ = try await self.openConnection(codeSigningRequirement: "")
        } catch XPCError.invalidCodeSignatureRequirement {
            failsConnectionInitialization.fulfill()
        }

        await fulfillment(of: [failsSignatureVerification, failsConnectionInitialization], timeout: 10.0)
    }

    func testSimpleRequestAndResponse() async throws {
        let conn = try await self.openConnection()

        let stringResponse: String = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "hi there")
        XCTAssertEqual(stringResponse, "HI THERE")

        let doubleResponse: Double = try await conn.sendMessage(name: CommandSet.multiplyBy5, request: 3.7)
        XCTAssertEqual(doubleResponse, 18.5, accuracy: 0.001)
    }

    func testDataTransport() async throws {
        let conn = try await self.openConnection()

        let dataInfo: DataInfo = try await conn.sendMessage(
            name: CommandSet.transportData,
            request: "One to beam up".data(using: .utf8)!
        )

        XCTAssertEqual(String(data: dataInfo.characterName, encoding: .utf8), "Lt. Cmdr. Data")
        XCTAssertEqual(String(data: dataInfo.playedBy, encoding: .utf8), "Brent Spiner")
        XCTAssertEqual(
            dataInfo.otherCharacters.map { String(data: $0, encoding: .utf8) },
            ["Lore", "B4", "Noonien Soong", "Arik Soong", "Altan Soong", "Adam Soong"]
        )

        XPCErrorRegistry.shared.registerDomain(forErrorType: DataInfo.DataError.self)
        let failsToSendBadData = self.expectation(description: "Fails to send bad data")

        do {
            try await conn.sendMessage(name: CommandSet.transportData, request: "It's Lore being sneaky".data(using: .utf8)!)
        } catch let error as DataInfo.DataError {
            XCTAssertEqual(error.failureReason, "fluctuation in the positronic matrix")
            failsToSendBadData.fulfill()
        }

        await fulfillment(of: [failsToSendBadData], timeout: 10.0)
    }

    func testTwoWayCommunication() async throws {
        let conn = try await self.openConnection()

        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)

        let asksForJoke = self.expectation(description: "We will get asked for a joke")
        let saysWhosThere = self.expectation(description: "The task will ask who's there")
        let asksWho = self.expectation(description: "The task will respond to our query and add 'who?'")
        let groans = self.expectation(description: "The task will not appreciate the joke")
        let expectations = [asksForJoke, saysWhosThere, asksWho, groans]
        expectations.forEach { $0.assertForOverFulfill = true }

        listener.setMessageHandler(name: JokeMessage.askForJoke) { _, response in
            XCTAssertEqual(response, "Tell me a joke")
            asksForJoke.fulfill()
            return "Knock knock"
        }

        listener.setMessageHandler(name: JokeMessage.whosThere) { _, response in
            XCTAssertEqual(response, "Who's there?")
            saysWhosThere.fulfill()
            return "Orange"
        }

        listener.setMessageHandler(name: JokeMessage.who) { _, response in
            XCTAssertEqual(response, "Orange who?")
            asksWho.fulfill()
            return "Orange you glad this example is so silly?"
        }

        listener.setMessageHandler(name: JokeMessage.groan) { _, response in
            XCTAssertEqual(response, "That was awful!")
            groans.fulfill()
        }

        listener.errorHandler = { _, error in
            if case .connectionInvalid = error as? XPCError {
                // connection can go down once we've received the last message
                return
            }

            DispatchQueue.main.async {
                XCTFail(error.localizedDescription)
            }
        }

        listener.activate()
        do {
            try await conn.sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)
        } catch {
            print("ERRRR", error)
        }

        await self.fulfillment(of: expectations, timeout: 10.0, enforceOrder: true)
    }

    func testTwoWayCommunicationWithError() async throws {
        XPCErrorRegistry.shared.registerDomain(forErrorType: JokeMessage.NotAKnockKnockJoke.self)
        let conn = try await self.openConnection()

        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)

        listener.setMessageHandler(name: JokeMessage.askForJoke) { _, response in
            XCTAssertEqual(response, "Tell me a joke")
            return "A `foo` walks into a `bar`"
        }

        listener.errorHandler = { _, error in
            if case .connectionInvalid = error as? XPCError {
                // connection can go down once we've received the last message
                return
            }

            DispatchQueue.main.async {
                XCTFail(error.localizedDescription)
            }
        }

        listener.activate()

        let failsToSendInvalidJoke = self.expectation(description: "Fails to send non-knock-knock joke")

        do {
            try await conn.sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)
        } catch let error as JokeMessage.NotAKnockKnockJoke {
            XCTAssertEqual(error.complaint, "That was not a knock knock joke!")
            failsToSendInvalidJoke.fulfill()
        }

        await fulfillment(of: [failsToSendInvalidJoke], timeout: 10.0)
    }

    func testOnewayVsTwoWay() async throws {
        let conn = try await self.openConnection()

        var date = Date.now
        try await conn.sendMessage(name: CommandSet.pauseOneSecond)
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(date), 1.0)

        date = Date.now
        try conn.sendOnewayMessage(name: CommandSet.pauseOneSecond, message: XPCNull())
        XCTAssertLessThan(Date.now.timeIntervalSince(date), 0.5)
    }

    func testCancelConnection() async throws {
        let conn = try await self.openConnection()

        let response: String = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "will work")
        XCTAssertEqual(response, "WILL WORK")

        try await conn.cancel()

        let err: Error?
        do {
            _ = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "won't work") as String
            err = nil
        } catch {
            err = error
        }

        guard case .connectionInvalid = err as? XPCError else {
            XCTFail("Sending message to cancelled connection should throw XPCError.connectionInvalid")
            return
        }
    }
    
    func testSimpleConnectionCounting() async throws {
        let conn = try await self.openConnection()

        var count: Int = try await conn.sendMessage(name: CommandSet.countConnections)
        XCTAssertEqual(count, 1)
        
        let conn2 = try await self.openConnection()
        
        count = try await conn.sendMessage(name: CommandSet.countConnections)
        XCTAssertEqual(count, 2)
        
        try await conn2.cancel()

        count = try await conn.sendMessage(name: CommandSet.countConnections)
        XCTAssertEqual(count, 1)
    }
    
    private func openConnection(codeSigningRequirement: String? = nil) async throws -> XPCConnection {
        let conn = try XPCConnection(
            type: .remoteMachService(serviceName: helperID, isPrivilegedHelperTool: false),
            codeSigningRequirement: codeSigningRequirement ?? self.helperLauncher?.codeSigningRequirement
        )
        try await conn.activate()

        return conn
    }
}
