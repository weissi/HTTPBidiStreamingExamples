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
import Dispatch
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - URLSession client

class PingPongyURLSession: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionStreamDelegate {
    private let sessionQueue: DispatchQueue
    private let calloutQueue: DispatchQueue
    private let completionHandler: (Error?) -> Void
    private let url: URL
    private let logger: Logger
    private let enableVaporWorkaround: Bool

    // thread safety: all on self.sessionQueue
    private var meToBuffer: OutputStream? = nil
    private var pingPongCounter = 1

    private enum State {
        case waitingForFirstBitsOfResponseStream
        case waitingForDollarSign
        case pingPonging(counter: Int)
    }

    init(url: URL,
         enableVaporWorkaround: Bool,
         calloutQueue: DispatchQueue,
         logger: Logger,
         completionHandler: @escaping (Error?) -> Void) {
        self.enableVaporWorkaround = enableVaporWorkaround
        self.url = url
        self.logger = {
            var logger = logger
            logger[metadataKey: "client"] = "URLSession"
            return logger
        }()
        self.completionHandler = completionHandler
        self.sessionQueue = DispatchQueue(label: "URLSession-q", target: calloutQueue)
        self.calloutQueue = DispatchQueue(label: "callout-q", target: calloutQueue)
    }

    private func checkQueue() {
        dispatchPrecondition(condition: .onQueue(self.sessionQueue))
    }

    func start() {
        self.sessionQueue.async {
            self.doIt()
        }
    }

    private func doIt() {
        self.checkQueue()

        let sOQ = OperationQueue()
        sOQ.underlyingQueue = self.sessionQueue
        let session: URLSession = URLSession(configuration: .default,
                                             delegate: self,
                                             delegateQueue: sOQ)

        // https://developer.apple.com/documentation/foundation/url_loading_system/uploading_streams_of_data
        var bufferToURLSession: InputStream? = nil
        Stream.getBoundStreams(withBufferSize: 4096,
                               inputStream: &bufferToURLSession,
                               outputStream: &self.meToBuffer)

        var request = URLRequest(url: self.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.httpBodyStream = bufferToURLSession
        request.httpMethod = "POST"

        self.meToBuffer!.schedule(in: .current, forMode: .default)
        self.meToBuffer!.open()

        let uploadTask = session.dataTask(with: request)
        uploadTask.resume()
        if self.enableVaporWorkaround {
            // Vapor only starts streaming if it sees a second `.body`.
            self.sendOne("VAPOR")
            usleep(100_000)
        }
        self.sendOne("1!") // kick-start this
    }

    private func sendOne(_ string: String) {
        self.checkQueue()

        var string = string
        let bytesSent = string.withUTF8 { ptr in
            self.meToBuffer!.write(ptr.baseAddress!, maxLength: ptr.count)
        }
        self.logger.debug("sent '\(string)', bytes transmitted: \(bytesSent)")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.checkQueue()

        self.logger.debug("received response body: \(String(decoding: data, as: UTF8.self))")

        if self.pingPongCounter > 10 {
            self.logger.info("We did 10 rounds of back and forth, streaming is working, let's close")
            self.meToBuffer?.close()
            return
        }
        self.pingPongCounter += 1
        self.sendOne("\(self.pingPongCounter)!")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.checkQueue()

        self.calloutQueue.async {
            self.completionHandler(error)
        }
    }
}
