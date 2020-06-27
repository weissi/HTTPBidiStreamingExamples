//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO
import NIOHTTP1
import AsyncHTTPClient
import Logging

enum Client: CaseIterable {
    case urlSession
    case asyncHTTPClient
}

enum Server: CaseIterable {
    case swiftNIO
    case vapor
}

protocol ServerImplementation {
    func start() throws -> URL
    func stop() throws
}

// MARK: - Driver

let logLevel = Logger.Level.debug

var driverLogger = { () -> Logger in
    var logger = Logger(label: "bidi-streaming.driver")
    logger.logLevel = logLevel
    return logger
}()

let clientLogger = { () -> Logger in
    var logger = Logger(label: "bidi-streaming.client")
    logger.logLevel = logLevel
    return logger
}()

let serverLogger = { () -> Logger in
    var logger = Logger(label: "bidi-streaming.server")
    logger.logLevel = logLevel
    return logger
}()

func runThatThing(client: Client, server: Server, group: EventLoopGroup) throws {
    let serverImpl: ServerImplementation
    switch server {
    case .swiftNIO:
        serverImpl = NIOEchoServer(group: group, logger: serverLogger)
    case .vapor:
        serverImpl = VaporEchoServer(group: group, logger: serverLogger)
    }
    let url = try serverImpl.start()
    defer {
        try! serverImpl.stop()
    }
    driverLogger[metadataKey: "driver"] = "client: \(client), server: \(server)"
    let dg = DispatchGroup()

    func evaluateFinalResult(_ error: Error?) {
        if let error = error {
            driverLogger.error("Final result: ❌ ERROR: \(error)")
        } else {
            driverLogger.info("Final result: ✅ OK")
        }
    }

    switch client {
    case .urlSession:
        driverLogger.info("Running HTTP client")
        dg.enter()
        let pingPongerURLSession = PingPongyURLSession(url: url,
                                                       calloutQueue: DispatchQueue(label: "foo"),
                                                       logger: clientLogger) { error in
            evaluateFinalResult(error)
            dg.leave()
        }
        pingPongerURLSession.start()

        dg.wait()
    case .asyncHTTPClient:
        driverLogger.info("Running AsyncHTTPClient client")
        dg.enter()
        let pingPongerAHC = PingPongyAHC(url: url,
                                         group: group,
                                         calloutQueue: DispatchQueue(label: "foo"),
                                         logger: clientLogger) { error in
            evaluateFinalResult(error)
            dg.leave()
        }
        pingPongerAHC.start()
        dg.wait()
        try! pingPongerAHC.stop()
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer {
    try! group.syncShutdownGracefully()
}

for server in Server.allCases {
    for client in Client.allCases {
        try runThatThing(client: client, server: server, group: group)
    }
}
