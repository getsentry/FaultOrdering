//
//  FaultOrderingTest.swift
//  EMGFaultOrdering
//
//  Created by Noah Martin on 5/17/25.
//

import Foundation
import MachO
import XCTest
import FlyingFox

enum Error: Swift.Error {
  case linkmapNotOpened
}

public final class Server: Sendable {

  public init(callback: @escaping @Sendable () -> Data) {
    server = HTTPServer(address: .loopback(port: 38825))
    self.callback = callback

    Task {
      try await startServer()
    }
  }

  private let server: HTTPServer
  private let callback: @Sendable () -> Data

  private func startServer() async throws {
    let callback = self.callback
    await server.appendRoute("GET /linkmap") { request in
      return HTTPResponse(statusCode: .ok, body: callback())
    }

    try await server.start()
  }
}

@MainActor
public class FaultOrderingTest {

  public init(setup: @escaping (XCUIApplication) -> Void) {
    self.setup = setup
  }

  private let setup: (XCUIApplication) -> Void

  private func getUsedAddresses(app: XCUIApplication, addresses: [Int]) -> Result {
    let data = try! JSONEncoder().encode(addresses)
    // Make the linkmap available to the app
    let s = Server(callback: { return data })

    // Launch the app for setup
    var launchEnvironment = app.launchEnvironment
    if let path = Self.getDylibPath(dylibName: "FaultOrdering") {
      launchEnvironment["DYLD_INSERT_LIBRARIES"] = path
    } else {
      print("FaultOrdering dylib not found, it will need to be linked to the app.")
    }
    launchEnvironment["RUN_FAULT_ORDER_SETUP"] = "1"
    app.launchEnvironment = launchEnvironment
    app.launch()
    setup(app)

    // Give the app some time to settle and write the order file
    sleep(10)

    // Launch the app for generating the order file
    launchEnvironment.removeValue(forKey: "RUN_FAULT_ORDER_SETUP")
    launchEnvironment["RUN_FAULT_ORDER"] = "1"
    app.launchEnvironment = launchEnvironment
    app.launch()

    guard let url = URL(string: "http://localhost:38824/file") else {
      preconditionFailure("Invalid URL")
    }
    // Give the app time to run and prepare the used addresses
    sleep(120)

    var resultData: Result?
    let request = URLRequest(url: url)
    let group = DispatchGroup()
    group.enter()

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      if let data = data {
        resultData = try! JSONDecoder().decode(Result.self, from: data)
      }
      group.leave()
    }
    task.resume()
    guard group.wait(timeout: .now().advanced(by: .seconds(10))) == .success else {
      preconditionFailure("Timed out waiting for used addresses.")
    }
    guard let resultData else {
      preconditionFailure("No result data found")
    }
    return resultData
  }

  public func testApp(testCase: XCTestCase, app: XCUIApplication) {
    let linkmap = try! getLinkmap()
    let symnameToSyms = Dictionary(grouping: linkmap.values, by: \.name)
    print("parsed linkmap with \(linkmap.count) symbols")

    let resultData = getUsedAddresses(app: app, addresses: Array(linkmap.keys))

    let images = resultData.loadedImages.sorted { first, second in
      first.loadAddress > second.loadAddress
    }
    var orderFileContents = [String]()
    var usedSymbols = Set<Symbol>()
    let addSymbol: (Symbol) -> Void = { sym in
      guard sym.eligableForOrderfile else { return }

      usedSymbols.insert(sym)
      let symsWithSameName = symnameToSyms[sym.name] ?? []
      if symsWithSameName.count > 1 {
        // If a symbol with the same name appears multiple times we can prefix it with the object file name.
        // However, the linker will still put all symbols with that name next to each other, not just
        // the one matching the object file. Additionally, if other symbols with the same name appear elsewhere
        // in the order file, none of them get ordered. So we add the rest of them to usedSymbols
        usedSymbols.formUnion(symsWithSameName)
        if let prefix = sym.obj.orderFilePrefix {
          orderFileContents.append("\(prefix):\(sym.name)")
        } else {
          orderFileContents.append(sym.name)
        }
      } else {
        orderFileContents.append(sym.name)
      }
    }
    for address in resultData.addresses {
      guard let image = images.first(where: { image in
        image.loadAddress < address
      }) else {
        print("Image not found")
        continue
      }

      if let symbol = linkmap[address - image.slide] {
        addSymbol(symbol)
      } else {
        print("Missing symbol at \(address - image.slide)")
      }
    }
    let remainingSymbols = Set(linkmap.values).subtracting(usedSymbols)
    orderFileContents.append("# begin remaining symbol")
    for s in remainingSymbols {
      addSymbol(s)
    }

    let attachment = XCTAttachment(string: orderFileContents.joined(separator: "\n"))
    attachment.lifetime = .keepAlways
    attachment.name = "order-file"
    testCase.add(attachment)
  }

  private static func getDylibPath(dylibName: String) -> String? {
    let count = _dyld_image_count()
    for i in 0..<count {
      if let imagePath = _dyld_get_image_name(i) {
        let imagePathStr = String(cString: imagePath)
        if (imagePathStr as NSString).lastPathComponent == dylibName {
          return imagePathStr
        }
      }
    }
    return nil
  }
}

struct Result: Decodable {
  let addresses: [Int]
  let loadedImages: [LoadedImage]

  struct LoadedImage: Decodable {
    let path: String
    let loadAddress: Int
    let slide: Int
  }
}
