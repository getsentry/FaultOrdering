//
//  Server.swift
//  EMGFaultOrdering
//
//  Created by Noah Martin on 5/17/25.
//

import Foundation
import FlyingFox

@objc(EMGServer)
public final class Server: NSObject, Sendable {

  @objc
  public init(callback: @escaping @Sendable () -> Data) {
    server = HTTPServer(address: .loopback(port: 38824))
    self.callback = callback
    super.init()

    Task {
      try await startServer()
    }
  }

  private let server: HTTPServer
  private let callback: @Sendable () -> Data

  func startServer() async throws {
    let callback = self.callback
    await server.appendRoute("GET /file") { request in
      return HTTPResponse(statusCode: .ok, body: callback())
    }

    try await server.start()
  }
}
