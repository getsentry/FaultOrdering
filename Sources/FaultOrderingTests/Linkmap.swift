//
//  Linkmap.swift
//  FaultOrdering
//
//  Created by Noah Martin on 5/28/25.
//

import Foundation

struct ObjectFile: Hashable {
  init(file: String, library: String?) {
    path = library != nil ? library! : file
    self.file = (file as NSString).lastPathComponent
    self.library = (library as? NSString)?.lastPathComponent
  }

  var orderFilePrefix: String? {
    if file.hasSuffix(".o") {
      return file
    }
    return nil
  }

  let path: String
  let file: String
  let library: String?
}

struct Symbol: Hashable {
  let name: String
  let obj: ObjectFile
  
  var eligableForOrderfile: Bool {
    !name.hasPrefix("l") && !name.contains("_OUTLINED_") && !(obj.library?.hasPrefix("GoogleMobileAds") ?? false)
  }
}

func getLinkmap() throws -> [Int: Symbol] {
  let linkmapPath = Bundle(for: FaultOrderingTest.self).path(forResource: "Linkmap", ofType: "txt")

  guard let file = fopen(linkmapPath, "r") else {
    throw Error.linkmapNotOpened
  }

  defer {
      fclose(file)
  }
  
  var buffer = [CChar](repeating: 0, count: 512)
  var inTextSection = false
  var inSections = false
  var inObjectFiles = false
  var textSectionStart: UInt64 = 0
  var textSectionSize: UInt64 = 0
  var result: [Int: Symbol] = [:]
  var objects = [ObjectFile]()
  while fgets(&buffer, Int32(buffer.count), file) != nil {
    // If buffer is completely full, skip (line too long)
    if buffer[511] != 0 {
      buffer = [CChar](repeating: 0, count: 512)
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
      var name = components[2]
      var objectIndex = 0
      if let range = name.range(of: "] ") {
        let stringObjIndex = String(name[name.index(name.startIndex, offsetBy: 1)..<range.lowerBound])
        objectIndex = Int(stringObjIndex) ?? 0
        name = String(name[range.upperBound...])
      }

      let symbol = Symbol(name: name, obj: objects[objectIndex])
      if sizeValue > 0 && symbol.eligableForOrderfile {
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
    } else if inObjectFiles {
      if let bracketIndex = line.index(of: "]") {
        let line = line[line.index(bracketIndex, offsetBy: 2)...]
        if let match = try? /^(.*?)(?:\((.*)\))?$/.firstMatch(in: line) {
          if let file = match.2.map { String($0) } {
            objects.append(ObjectFile(file: file, library: String(match.1)))
          } else {
            objects.append(ObjectFile(file: String(match.1), library: nil))
          }
        }
      }
    }
    
    if !inObjectFiles {
      if line.contains("# Object files:") {
        inObjectFiles = true
      }
    }
  }
  return result
}
