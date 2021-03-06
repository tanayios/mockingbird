//
//  CodableTarget.swift
//  MockingbirdGenerator
//
//  Created by Andrew Chang on 9/29/19.
//

import Foundation
import PathKit
import XcodeProj

// MARK: - XcodeProj adapters

public protocol TargetDependency: Hashable {
  associatedtype T where T: Target
  var target: T? { get }
}

public protocol AbstractTarget {
  var productModuleName: String { get }
}

public protocol Target: AbstractTarget, Hashable {
  associatedtype D where D: TargetDependency
  
  var name: String { get }
  var dependencies: [D] { get }
  
  func findSourceFilePaths(sourceRoot: Path) -> [Path]
}

// MARK: - Codable

public class CodableTargetDependency: TargetDependency, Codable {
  public let target: CodableTarget?
  
  init?<D: TargetDependency>(from dependency: D,
                             sourceRoot: Path,
                             ignoredDependencies: inout Set<String>) throws {
    guard let target = dependency.target else { return nil }
    self.target = try CodableTarget(from: target,
                                    sourceRoot: sourceRoot,
                                    ignoredDependencies: &ignoredDependencies)
  }
  
  public static func == (lhs: CodableTargetDependency, rhs: CodableTargetDependency) -> Bool {
    return lhs.target == rhs.target
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(target)
  }
}

public struct SourceFile: Codable, Hashable {
  public let path: String
  public let hash: String?
}

public class CodableTarget: Target, Codable {
  public let name: String
  public let productModuleName: String
  public let dependencies: [CodableTargetDependency]
  
  public let sourceFilePaths: [SourceFile]
  public let supportingFilePaths: [SourceFile]?
  public let sourceRoot: String
  public let projectHash: String?
  public let outputHash: String?
  public let targetPathsHash: String?
  public let dependencyPathsHash: String?
  public let cliVersion: String?
  
  public init<T: Target>(from target: T,
                         sourceRoot: Path,
                         supportPaths: [Path]? = nil,
                         projectHash: String? = nil,
                         outputHash: String? = nil,
                         targetPathsHash: String? = nil,
                         dependencyPathsHash: String? = nil,
                         cliVersion: String? = nil,
                         ignoredDependencies: inout Set<String>) throws {
    self.name = target.name
    self.productModuleName = target.productModuleName
    self.dependencies = try target.dependencies
      .filter({ !ignoredDependencies.contains($0.target?.productModuleName ?? "") })
      .compactMap({ try CodableTargetDependency(from: $0,
                                                sourceRoot: sourceRoot,
                                                ignoredDependencies: &ignoredDependencies) })
    ignoredDependencies.formUnion(self.dependencies.map({ $0.target?.productModuleName ?? "" }))
    self.sourceFilePaths = try target.findSourceFilePaths(sourceRoot: sourceRoot)
      .map({ $0.absolute() })
      .sorted()
      .map({ try SourceFile(path: "\($0)", hash: $0.read().generateSha1Hash()) })
    self.supportingFilePaths = try supportPaths?
      .map({ $0.absolute() })
      .sorted()
      .map({ try SourceFile(path: "\($0)", hash: $0.read().generateSha1Hash()) })
    self.targetPathsHash = targetPathsHash
    self.dependencyPathsHash = dependencyPathsHash
    self.sourceRoot = "\(sourceRoot.absolute())"
    self.projectHash = projectHash
    self.outputHash = outputHash
    self.cliVersion = cliVersion
  }
  
  public func findSourceFilePaths(sourceRoot: Path) -> [Path] {
    guard "\(sourceRoot.absolute())" == self.sourceRoot else {
      logWarning("Cached source root does not match the input source root") // Should never happen
      return []
    }
    return sourceFilePaths.map({ Path($0.path) })
  }
  
  public static func == (lhs: CodableTarget, rhs: CodableTarget) -> Bool {
    return lhs.productModuleName == rhs.productModuleName
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(productModuleName)
  }
}

// MARK: - XcodeProj conformance

extension PBXTarget: AbstractTarget {}

extension PBXTarget: Target {
  /// Get the build configuration for testing, which is almost always `debug`.
  // TODO: Allow overriding for special cases via CLI argument.
  var testingBuildConfiguration: XCBuildConfiguration? {
    guard let inferredBuildConfiguration = buildConfigurationList?.buildConfigurations
      .first(where: { $0.name.lowercased() == "debug" }) else {
        logWarning("No debug build configuration found for target `\(name)`")
        return buildConfigurationList?.buildConfigurations.first
    }
    return inferredBuildConfiguration
  }
  
  public var productModuleName: String {
    guard
      let buildConfiguration = testingBuildConfiguration,
      let buildSetting =
        buildConfiguration.buildSettings["PRODUCT_MODULE_NAME"] as? String ??
        buildConfiguration.buildSettings["PRODUCT_NAME"] as? String,
      let moduleName = buildConfiguration.resolve(buildSetting, for: self)
    else {
      let fallbackModuleName = name.replacingInvalidCharacters()
      log("No explicit module name set for target `\(name)`, falling back to `\(fallbackModuleName)`")
      return fallbackModuleName
    }
    return moduleName.replacingInvalidCharacters()
  }

  public func findSourceFilePaths(sourceRoot: Path) -> [Path] {
    guard let phase = buildPhases.first(where: { $0.buildPhase == .sources }) else { return [] }
    return phase.files?
      .compactMap({ try? $0.file?.fullPath(sourceRoot: sourceRoot) })
      .filter({ $0.extension == "swift" }) ?? []
  }
}

extension XCBuildConfiguration {
  /// Certain build settings are implicitly applied, such as `TARGET_NAME`.
  func getBuildSetting(named key: String, for target: PBXTarget) -> String? {
    let implicitBuildSettings: [String: String] = [
      "TARGET_NAME": target.name
    ]
    return buildSettings[key] as? String ?? implicitBuildSettings[key]
  }
  
  /// Recursively resolves build settings.
  func resolve(_ buildSetting: String?, for target: PBXTarget) -> String? {
    guard let buildSetting = buildSetting else { return nil }
    
    let trimmedBuildSetting = buildSetting.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedBuildSetting.hasPrefix("$("), trimmedBuildSetting.hasSuffix(")") else { return buildSetting }
    
    let buildSettingName: String
    if let endIndex = trimmedBuildSetting.firstIndex(of: ":") { // e.g. `$(TARGET_NAME:c99exidentifier)`
      let startIndex = trimmedBuildSetting.index(trimmedBuildSetting.startIndex, offsetBy: 2)
      buildSettingName = String(trimmedBuildSetting[startIndex..<endIndex])
    } else { // e.g. `$(TARGET_NAME)`
      buildSettingName = trimmedBuildSetting.drop(first: 2, last: 1)
    }
    
    return resolve(getBuildSetting(named: buildSettingName, for: target), for: target)
  }
}

extension PBXTargetDependency: TargetDependency {}

private extension String {
  func replacingInvalidCharacters() -> String {
    let replaced = replacingOccurrences(of: "\\W", with: "_", options: .regularExpression)
    if String(replaced[startIndex]).range(of: "\\d", options: .regularExpression) != nil {
      return replaced.replacingCharacters(in: ...startIndex, with: "_")
    } else {
      return replaced
    }
  }
}
