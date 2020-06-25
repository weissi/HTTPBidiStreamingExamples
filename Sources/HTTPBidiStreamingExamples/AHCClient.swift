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

import AsyncHTTPClient
import NIO
import Dispatch
import Logging
import struct Foundation.URL

class PingPongyAHC: HTTPClientResponseDelegate {
    typealias Response = Void

    private let calloutQueue: DispatchQueue
    private let completionHandler: (Error?) -> Void
    private let url: URL
    private let httpClient: HTTPClient
    private let eventLoop: EventLoop
    private let logger: Logger
    private let enableVaporWorkaround: Bool

    // thread safety: all only on self.eventLoop
    private var bodyDonePromise: Optional<EventLoopPromise<Void>> = nil
    private var streamWriter: Optional<HTTPClient.Body.StreamWriter> = nil
    private var pingPongCounter = 1

    private enum State {
        case waitingForFirstBitsOfResponseStream
        case waitingForDollarSign
        case pingPonging(counter: Int)
    }

    init(url: URL,
         enableVaporWorkaround: Bool,
         group: EventLoopGroup,
         calloutQueue: DispatchQueue,
         logger: Logger,
         completionHandler: @escaping (Error?) -> Void) {
        self.logger = {
            var logger = logger
            logger[metadataKey: "client"] = "AsyncHTTPClient"
            return logger
        }()
        self.enableVaporWorkaround = enableVaporWorkaround
        self.url = url
        self.completionHandler = completionHandler
        self.calloutQueue = DispatchQueue(label: "callout-q", target: calloutQueue)
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(group))
        self.eventLoop = group.next()
    }

    func start() {
        let request = try! HTTPClient.Request(url: self.url,
                                         method: .POST,
                                         body: .stream { writer in
                                            self.logger.debug("received stream writer")
                                            assert(self.bodyDonePromise == nil)
                                            self.streamWriter = writer
                                            if self.enableVaporWorkaround {
                                                _ = self.sendOne("VAPOR").flatMap {
                                                    self.sendOne("1!")
                                                }
                                            } else {
                                                _ = self.sendOne("1!")
                                            }
                                            self.bodyDonePromise = self.eventLoop.makePromise()
                                            return self.bodyDonePromise!.futureResult
                                         })
        self.httpClient.execute(request: request,
                                delegate: self,
                                eventLoop: .delegate(on: self.eventLoop),
                                deadline: .now() + .seconds(5),
                                logger: self.logger).futureResult.whenComplete { result in
                                    switch result {
                                    case .success:
                                        self.calloutQueue.async {
                                            self.completionHandler(nil)
                                        }
                                    case .failure(let error):
                                        self.calloutQueue.async {
                                            self.completionHandler(error)
                                        }
                                    }
                                }
    }

    func stop() throws {
        try self.httpClient.syncShutdown()
    }

    private func doIt() {
        self.eventLoop.preconditionInEventLoop()
    }

    private func sendOne(_ string: String) -> EventLoopFuture<Void> {
        self.eventLoop.preconditionInEventLoop()

        return self.streamWriter!.write(.byteBuffer(ByteBuffer(string: string))).map {
            self.logger.debug("sent '\(string)'")
        }
    }

    func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
        self.bodyDonePromise?.fail(error)
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        self.logger.debug("received '\(String(buffer: buffer))'")

        if self.pingPongCounter > 10 {
            self.logger.info("CLIENT: We did 10 rounds of back and forth, streaming is working, let's close")
            self.bodyDonePromise?.succeed(())
            self.bodyDonePromise = nil
            return self.eventLoop.makeSucceededFuture(())
        }

        self.pingPongCounter += 1
        return self.sendOne("\(self.pingPongCounter)!")
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws -> Void {
        self.eventLoop.preconditionInEventLoop()
    }
}
