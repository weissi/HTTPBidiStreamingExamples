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

import NIO
import NIOHTTP1
import Logging
import struct Foundation.URL
import struct Foundation.UUID

final class NIOEchoServer: ServerImplementation {
    private var server: Optional<Channel> = nil
    private let group: EventLoopGroup
    private var logger: Logger

    init(group: EventLoopGroup, logger: Logger) {
        self.group = group
        self.logger = {
            var logger = logger
            logger[metadataKey: "server"] = "SwiftNIO"
            return logger
        }()
    }

    func start() throws -> URL {
        self.server = try ServerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPEchoServer(logger: self.logger))
                }
            }
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let url = URL(string: "http://127.0.0.1:\(self.server!.localAddress!.port!)/echo")!
        self.logger.info("Server up and running at \(url)")
        return url
    }

    func stop() throws {
        try self.server!.close().wait()
    }
}

// MARK: - NIO HTTP Echo Server

private final class HTTPEchoServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let logger: Logger

    init(logger: Logger) {
        self.logger = {
            var logger = logger
            logger[metadataKey: "request-uuid"] = "\(UUID())"
            return logger
        }()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let reqHead):
            self.logger.info("request head: \(reqHead)")
            let responseHead = HTTPServerResponsePart.head(.init(version: .init(major: 1, minor: 1),
                                                                 status: .ok,
                                                                 headers: ["request-uri": reqHead.uri,
                                                                           "Content-Type": "application/octet-stream"]))
            context.writeAndFlush(self.wrapOutboundOut(responseHead), promise: nil)
        case .body(let buffer):
            self.logger.debug("request body: \(String(buffer: buffer))")
            context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        case .end:
            self.logger.info("request end")
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.logger.error("closing connection, unexpected error: \(error)")
        context.close(promise: nil)
    }
}
