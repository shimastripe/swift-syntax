//===------------------- Syntax+Assertions.swift  -------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// Syntax assertion helpers.
//
//===----------------------------------------------------------------------===//

import SwiftSyntax
import XCTest

/// Verifies that there is a next item returned by the iterator and that it
/// satisfies the given predicate.
public func XCTAssertNext<Iterator: IteratorProtocol>(
  _ iterator: inout Iterator,
  satisfies predicate: (Iterator.Element) throws -> Bool,
  file: StaticString = #filePath, line: UInt = #line
) throws {
  let next = try XCTUnwrap(iterator.next(), file: file, line: line)
  XCTAssertTrue(try predicate(next), file: file, line: line)
}

/// Verifies that the iterator is exhausted.
public func XCTAssertNextIsNil<Iterator: IteratorProtocol>(_ iterator: inout Iterator) {
  XCTAssertNil(iterator.next())
}

/// Allows matching a subtrees of the given `markedText` against
/// `baseline`/`expected` trees, where a combination of markers and the type
/// of the `expected` tree is used to first find the subtree to match. Note
/// any markers are removed before the source is parsed.
///
/// As an example, given some source with markers to parse:
/// ```
/// let subtreeMatcher = SubtreeMatcher("""
///   func foo(#^FIRST^#x y: Double,
///   #^SECOND^#first second third: Int) {}
///   """
/// ```
///
/// And then some asserts:
/// ```
/// let firstExpectedParam = ... // make the first expected parameter
/// subtreeMatcher.assertSameStructure(from: "FIRST", firstExpectedParam)
///
/// let secondExpectedParam = ... // make the second expected parameter
/// subtreeMatcher.assertSameStructure(from: "SECOND", secondExpectedParam)
/// ```
///
/// Before parsing, `#^FIRST^#` and `#^SECOND^#` will first be removed from the
/// source test.
///
/// The subtree matched in `FIRST` will start at the first node after
/// `#^FIRST^#` that matches the root type of `firstExpectedParam`.
///
/// There's no *need* to specify a marker, eg. if we want to match on the first
/// parameter only we could instead write:
/// ```
/// let subtreeMatcher = SubtreeMatcher("""
///   func foo(first second third: Int) {}
///   """
/// let expectedParam = ... // make the first expected parameter
/// subtreeMatcher.assertSameStructure(expectedParam)
/// ```
///
/// Since no marker was given the matched subtree will just start at the first
/// node matching `expectedParam`'s type.
public struct SubtreeMatcher {
  /// Maps marker names to the UTF-8 byte offset for the character at which
  /// they occurred in the source *with markers removed*.
  private let markers: [String: Int]
  /// The syntax tree from parsing source *with markers removed*.
  private var actualTree: Syntax

  public init(_ markedText: String, parse: (String) throws -> Syntax) throws {
    let (markers, text) = extractMarkers(markedText)

    self.markers = markers.isEmpty ? ["DEFAULT": 0] : markers
    self.actualTree = try parse(text)
  }

  public init(_ actualTree: Syntax, markers: [String: Int]) {
    self.markers = markers.isEmpty ? ["DEFAULT": 0] : markers
    self.actualTree = actualTree
  }

  /// Same as `Syntax.findFirstDifference(baseline:includeTrivia:)`, but
  /// matches against the first subtree from parsing `markedText` that is after
  /// `afterMarker` with the root matching the root type of `baseline`.
  public func findFirstDifference(afterMarker: String? = nil, baseline: Syntax, includeTrivia: Bool = false) throws -> TreeDifference? {
    let afterMarker = afterMarker ?? markers.first!.key
    guard let subtreeStart = markers[afterMarker] else {
      throw SubtreeError.invalidMarker(name: afterMarker)
    }

    guard let subtree = SyntaxTypeFinder.findFirstNode(in: actualTree, afterUTF8Offset: subtreeStart, ofType: baseline.syntaxNodeType) else {
      throw SubtreeError.invalidSubtree(tree: actualTree, afterUTF8Offset: subtreeStart, type: String(describing: baseline.syntaxNodeType))
    }

    return subtree.findFirstDifference(baseline: baseline, includeTrivia: includeTrivia)
  }

  /// Verifies that the the subtree found from parsing the text passed into
  /// `init(markedText:)` has the same structure as `expected`.
  public func assertSameStructure(afterMarker: String? = nil, _ expected: Syntax, includeTrivia: Bool = false,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
    if let diff = try findFirstDifference(afterMarker: afterMarker, baseline: expected, includeTrivia: includeTrivia) {
      XCTFail(diff.debugDescription, file: file, line: line)
    }
  }
}

public enum SubtreeError: Error, CustomStringConvertible {
  case invalidMarker(name: String)
  case invalidSubtree(tree: Syntax, afterUTF8Offset: Int, type: String)

  public var description: String {
    switch self {
    case let .invalidMarker(name):
      return "Could not find marker with name '\(name)'"
    case let .invalidSubtree(tree, afterUTF8Offset, type):
      return "Could not find subtree after UTF8 offset \(afterUTF8Offset) with type \(type) in:\n\(tree.debugDescription(includeChildren: true))"
    }
  }
}

fileprivate class SyntaxTypeFinder: SyntaxAnyVisitor {
  private let offset: Int
  private let type: SyntaxProtocol.Type
  private var found: Syntax?

  private init(offset: Int, type: SyntaxProtocol.Type) {
    self.offset = offset
    self.type = type
    self.found = nil
    super.init(viewMode: .all)
  }

  fileprivate override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    if found != nil || node.endPosition.utf8Offset < offset {
      return .skipChildren
    }

    if node.positionAfterSkippingLeadingTrivia.utf8Offset >= offset && node.syntaxNodeType == type {
      found = node
      return .skipChildren
    }

    return .visitChildren
  }

  public static func findFirstNode(in tree: Syntax, afterUTF8Offset offset: Int, ofType type: SyntaxProtocol.Type) -> Syntax? {
    let finder = SyntaxTypeFinder(offset: offset, type: type)
    finder.walk(tree)
    return finder.found
  }
}
