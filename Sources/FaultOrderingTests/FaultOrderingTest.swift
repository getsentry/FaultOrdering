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
  
  func getLinkmap() throws -> Linkmap {
    let linkmapPath = Bundle(for: FaultOrderingTest.self).path(forResource: "Linkmap", ofType: "txt")

    guard let file = fopen(linkmapPath, "r") else {
      throw Error.linkmapNotOpened
    }

    defer {
        fclose(file)
    }
    
    var buffer = [CChar](repeating: 0, count: 256)
    var inTextSection = false
    var inSections = false
    var textSectionStart: UInt64 = 0
    var textSectionSize: UInt64 = 0
    var result: [Int: String] = [:]
    while fgets(&buffer, Int32(buffer.count), file) != nil {
      // If buffer is completely full, skip (line too long)
      if buffer[255] != 0 {
        buffer = [CChar](repeating: 0, count: 256)
        continue
      }
      
      let line = String(cString: buffer).trimmingCharacters(in: .newlines)
      if !inTextSection {
          if line.contains("# Symbols:") {
              inTextSection = true
          }
      }
      if !inSections && !inTextSection {
        if line.contains("# Sections:") {
          inSections = true
        }
      }
      if inTextSection {
        guard line.hasPrefix("0x") else {
            continue
        }
        
        var components = line.split(separator: "\t", maxSplits: 2).map(String.init)
        guard components.count == 3 else {
            continue
        }

        let addressStr = components[0]
        let sizeStr = components[1]
        let sizeValue = UInt64(sizeStr.dropFirst(2), radix: 16) ?? 0
        var symbol = components[2]
        if let range = symbol.range(of: "] ") {
            symbol = String(symbol[range.upperBound...])
        }

        if sizeValue > 0 && !symbol.hasPrefix("l") && !symbol.contains("_OUTLINED_") {
            let addrHex = addressStr.dropFirst(2) // Remove "0x"
            if let addrValue = UInt64(addrHex, radix: 16) {
              let sectionEnd = textSectionStart + textSectionSize
              if addrValue >= textSectionStart && addrValue < sectionEnd {
                result[Int(addrValue)] = symbol
              } else {
                break
              }
            }
        }
      } else if inSections {
        if line.contains("__TEXT\t__text") {
          var components = line.split(separator: "\t", maxSplits: 2).map(String.init)
          guard components.count == 3 else {
            continue
          }
          textSectionStart = UInt64(components[0].dropFirst(2), radix: 16) ?? 0
          textSectionSize = UInt64(components[1].dropFirst(2), radix: 16) ?? 0
        }
      }
    }
    return result
  }
  
  public func testApp(testCase: XCTestCase, app: XCUIApplication, insertLibrary: Bool) {
    let linkmap = try! getLinkmap()
    print("parsed linkmap with \(linkmap.count) symbols")
    let data = try! JSONEncoder().encode(Array(linkmap.keys))
    // Make the linkmap available to the app
    let s = Server(callback: { return data })
    
    // Launch the app for setup
    var launchEnvironment = app.launchEnvironment
    if insertLibrary {
      if let path = Self.getDylibPath(dylibName: "FaultOrdering") {
        launchEnvironment["DYLD_INSERT_LIBRARIES"] = path
      } else {
        print("FaultOrdering dylib not found, it will need to be linked to the app.")
      }
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
    sleep(10)
    

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
    guard group.wait(timeout: .now().advanced(by: .seconds(150))) == .success else {
      preconditionFailure("test timed out")
    }
    guard let resultData else {
      preconditionFailure("No result data found")
    }
    let images = resultData.loadedImages.sorted { first, second in
      first.loadAddress > second.loadAddress
    }
    var orderFileContents = ""
    for address in resultData.addresses {
      guard let image = images.first(where: { image in
        image.loadAddress < address
      }) else {
        print("Image not found")
        continue
      }

      if let symbol = linkmap[address - image.slide] {
        orderFileContents.append(symbol + "\n")
      } else {
        print("Missing symbol at \(address - image.slide)")
      }
    }
    let attachment = XCTAttachment(string: orderFileContents)
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

typealias Linkmap = [Int: String]
