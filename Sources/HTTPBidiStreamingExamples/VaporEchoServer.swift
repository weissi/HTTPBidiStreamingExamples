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

import Vapor

final class VaporEchoServer: ServerImplementation {
    private var app: Optional<Application> = nil
    private let group: EventLoopGroup
    private let logger: Logger

    init(group: EventLoopGroup, logger: Logger) {
        self.group = group
        self.logger = {
            var logger = logger
            logger[metadataKey: "server"] = "Vapor"
            return logger
        }()
    }

    func start() throws -> URL {
         // no idea how I can have Vapor pick a free port automatically and tell me what it picked
        let port = (30000 ..< 60000).randomElement()!
        let environment = try Environment.detect()
        self.app = Application(environment, .shared(self.group))
        self.app!.logger = self.logger
        self.app!.http.server.configuration.hostname = "127.0.0.1"
        self.app!.http.server.configuration.port = port

        self.app!.on(.POST, "echo", body: .stream)  { request -> Response in
            request.logger.info("recevied request")
            let r = Response(status: .ok, body: .init(stream: { writer in
                request.body.drain { body in
                    switch body {
                    case .buffer(let buffer):
                        request.logger.debug("received body \(String(buffer: buffer))")
                        return writer.write(.buffer(buffer))
                    case .error(let error):
                        request.logger.error("unexpected error: \(error)")
                        return writer.write(.error(error))
                    case .end:
                        request.logger.info("request done")
                        return writer.write(.end)
                    }
                }
            }))
            r.headers.add(name: "content-type", value: "application/octet-stream")
            return r
        }

        let url = URL(string: "http://127.0.0.1:\(port)/echo")!
        try self.app!.start()
        self.logger.info("Server up and running at \(url)")
        return url
    }

    func stop() throws {
        self.app!.shutdown()
    }
}
