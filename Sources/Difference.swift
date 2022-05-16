//
//  Difference.swift
//  Difference
//
//  Created by Krzysztof Zablocki on 18.10.2017
//  Copyright © 2017 Krzysztof Zablocki. All rights reserved.
//

import Foundation

private typealias IndentationType = Difference.IndentationType

public struct DifferenceNameLabels {
    let expected: String
    let received: String
    let missing: String
    let extra: String

    public init(expected: String, received: String, missing: String, extra: String) {
        self.expected = expected
        self.received = received
        self.missing = missing
        self.extra = extra
    }

    public static var expectation: Self {
        Self(
            expected: "Expected",
            received: "Received",
            missing: "Missing",
            extra: "Extra"
        )
    }

    public static var comparing: Self {
        Self(
            expected: "Previous",
            received: "Current",
            missing: "Removed",
            extra: "Added"
        )
    }
}

private struct Differ {
    private let indentationType: IndentationType
    private let skipPrintingOnDiffCount: Bool
    private let nameLabels: DifferenceNameLabels

    init(
        indentationType: IndentationType,
        skipPrintingOnDiffCount: Bool,
        nameLabels: DifferenceNameLabels
    ) {
        self.indentationType = indentationType
        self.skipPrintingOnDiffCount = skipPrintingOnDiffCount
        self.nameLabels = nameLabels
    }

    func diff<T>(_ expected: T, _ received: T) -> [String] {
        let lines = diffLines(expected, received, level: 0)
        return buildLineContents(lines: lines)
    }

    fileprivate func diffLines<T>(_ expected: T, _ received: T, level: Int = 0) -> [Line] {
        let expectedMirror = Mirror(reflecting: expected)
        let receivedMirror = Mirror(reflecting: received)

        guard expectedMirror.children.count != 0, receivedMirror.children.count != 0 else {
            if String(dumping: received) != String(dumping: expected) {
                return handleChildless(expected, expectedMirror, received, receivedMirror, level)
            } else if expectedMirror.unwrapped?.displayStyle == .enum {
                let expectedValue = enumIntValue(for: expected)
                let receivedValue = enumIntValue(for: received)
                if expectedValue != receivedValue {
                    return handleChildless(expectedValue, expectedMirror, receivedValue, receivedMirror, level)
                }
            }
            return []
        }

        let hasDiffNumOfChildren = expectedMirror.children.count != receivedMirror.children.count
        switch (expectedMirror.displayStyle, receivedMirror.displayStyle) {
        case (.collection?, .collection?) where hasDiffNumOfChildren,
             (.dictionary?, .dictionary?) where hasDiffNumOfChildren,
             (.set?, .set?) where hasDiffNumOfChildren,
             (.enum?, .enum?) where hasDiffNumOfChildren:
            return [generateDifferentCountBlock(expected, expectedMirror, received, receivedMirror, level)]
        case (.dictionary?, .dictionary?):
            if let expectedDict = expected as? Dictionary<AnyHashable, Any>,
                let receivedDict = received as? Dictionary<AnyHashable, Any> {
                var resultLines: [Line] = []
                let missingKeys = Set(expectedDict.keys).subtracting(receivedDict.keys)
                let extraKeys = Set(receivedDict.keys).subtracting(expectedDict.keys)
                let commonKeys = Set(receivedDict.keys).intersection(expectedDict.keys)
                commonKeys.forEach { key in
                    let results = diffLines(expectedDict[key], receivedDict[key], level: level + 1)
                    if !results.isEmpty {
                        resultLines.append(Line(contents: "Key \(key.description):", indentationLevel: level, canBeOrdered: true, children: results))
                    }
                }
                if (!missingKeys.isEmpty) {
                    var missingKeyPairs: [Line] = []
                    missingKeys.forEach { key in
                        missingKeyPairs.append(Line(contents: "\(key.description): \(String(describing: expectedDict[key]))", indentationLevel: level + 1, canBeOrdered: true))
                    }
                    resultLines.append(Line(contents: "\(nameLabels.missing) key pairs:", indentationLevel: level, canBeOrdered: false, children: missingKeyPairs))
                }
                if (!extraKeys.isEmpty) {
                    var extraKeyPairs: [Line] = []
                    extraKeys.forEach { key in
                        extraKeyPairs.append(Line(contents: "\(key.description): \(String(describing: receivedDict[key]))", indentationLevel: level + 1, canBeOrdered: true))
                    }
                    resultLines.append(Line(contents: "\(nameLabels.extra) key pairs:", indentationLevel: level, canBeOrdered: false, children: extraKeyPairs))
                }
                return resultLines
            }
        case (.set?, .set?):
            if let expectedSet = expected as? Set<AnyHashable>,
                let receivedSet = received as? Set<AnyHashable> {
                let missing = expectedSet.subtracting(receivedSet)
                    .map { unique in
                        Line(contents: "\(nameLabels.missing): \(unique.description)", indentationLevel: level, canBeOrdered: true)
                    }
                let extras = receivedSet.subtracting(expectedSet)
                    .map { unique in
                        Line(contents: "\(nameLabels.extra): \(unique.description)", indentationLevel: level, canBeOrdered: true)
                    }
                return missing + extras
            }
        // Handles different enum cases that have children to prevent printing entire object
        case (.enum?, .enum?) where expectedMirror.children.first?.label != receivedMirror.children.first?.label:
            let expectedPrintable = enumLabelFromFirstChild(expectedMirror) ?? "UNKNOWN"
            let receivedPrintable = enumLabelFromFirstChild(receivedMirror) ?? "UNKNOWN"
            return generateExpectedReceiveLines(expectedPrintable, receivedPrintable, level)
        default:
            break
        }

        var resultLines = [Line]()
        let zipped = zip(expectedMirror.children, receivedMirror.children)
        zipped.enumerated().forEach { (index, zippedValues) in
            let lhs = zippedValues.0
            let rhs = zippedValues.1
            let childName = "\(expectedMirror.displayStyleDescriptor(index: index))\(lhs.label ?? ""):"
            let leftDump = String(dumping: lhs.value)
            if leftDump != String(dumping: rhs.value) {
                // Remove embedding of `some` for optional types, as it offers no value
                guard expectedMirror.displayStyle != .optional else {
                    let results = diffLines(lhs.value, rhs.value, level: level)
                    resultLines.append(contentsOf: results)
                    return
                }
                if Mirror(reflecting: lhs.value).displayStyle != nil {
                    let results = diffLines(lhs.value, rhs.value, level: level + 1)
                    if !results.isEmpty {
                        let line = Line(contents: childName,
                            indentationLevel: level,
                            canBeOrdered: true,
                            children: results
                        )
                        resultLines.append(line)
                    }
                } else {
                    let children = generateExpectedReceiveLines(
                        String(describing: lhs.value),
                        String(describing: rhs.value),
                        level + 1
                    )
                    resultLines.append(Line(contents: childName, indentationLevel: level, canBeOrdered: true, children: children))
                }
            } else if Mirror(reflecting: lhs.value).unwrapped?.displayStyle == .enum {
                let expectedValue = enumIntValue(for: lhs.value)
                let receivedValue = enumIntValue(for: rhs.value)
                if expectedValue != receivedValue {
                    let children = generateExpectedReceiveLines(
                        String(describing: expectedValue),
                        String(describing: receivedValue),
                        level + 1
                    )
                    resultLines.append(Line(contents: childName, indentationLevel: level, canBeOrdered: true, children: children))
                }
            }
        }
        return resultLines
    }

    fileprivate func handleChildless<T>(
        _ expected: T,
        _ expectedMirror: Mirror,
        _ received: T,
        _ receivedMirror: Mirror,
        _ indentationLevel: Int
    ) -> [Line] {
        // Empty collections are "childless", so we may need to generate a different count block instead of treating as a
        // childless enum.
        guard !expectedMirror.canBeEmpty else {
            return [generateDifferentCountBlock(expected, expectedMirror, received, receivedMirror, indentationLevel)]
        }

        let receivedPrintable: String
        let expectedPrintable: String
        // Received mirror has a different number of arguments to expected
        if receivedMirror.children.count == 0, expectedMirror.children.count != 0 {
            // Print whole description of received, as it's only a label if childless
            receivedPrintable = String(dumping: received)
            // Get the label from the expected, to prevent printing long list of arguments
            expectedPrintable = enumLabelFromFirstChild(expectedMirror) ?? String(describing: expected)
        } else if expectedMirror.children.count == 0, receivedMirror.children.count != 0 {
            receivedPrintable = enumLabelFromFirstChild(receivedMirror) ?? String(describing: received)
            expectedPrintable = String(dumping: expected)
        } else {
            receivedPrintable = String(describing: received)
            expectedPrintable = String(describing: expected)
        }
        return generateExpectedReceiveLines(expectedPrintable, receivedPrintable, indentationLevel)
    }

    private func generateDifferentCountBlock<T>(
        _ expected: T,
        _ expectedMirror: Mirror,
        _ received: T,
        _ receivedMirror: Mirror,
        _ indentationLevel: Int
    ) -> Line {
        var expectedPrintable = "(\(expectedMirror.children.count))"
        var receivedPrintable = "(\(receivedMirror.children.count))"
        if !skipPrintingOnDiffCount {
            expectedPrintable.append(" \(expected)")
            receivedPrintable.append(" \(received)")
        }
        return Line(
            contents: "Different count:",
            indentationLevel: indentationLevel,
            canBeOrdered: false,
            children: generateExpectedReceiveLines(expectedPrintable, receivedPrintable, indentationLevel + 1)
        )
    }

    private func generateExpectedReceiveLines(
        _ expected: String,
        _ received: String,
        _ indentationLevel: Int
    ) -> [Line] {
        return [
            Line(contents: "\(nameLabels.received): \(received)", indentationLevel: indentationLevel, canBeOrdered: false),
            Line(contents: "\(nameLabels.expected): \(expected)", indentationLevel: indentationLevel, canBeOrdered: false)
        ]
    }

    private func buildLineContents(lines: [Line]) -> [String] {
        let linesContents = lines.map { line in line.generateContents(indentationType: indentationType) }
        // In the case of this being a top level failure (e.g. both mirrors have no children, like comparing two
        // primitives `diff(2,3)`, we only want to produce one failure to have proper spacing.
        let isOnlyTopLevelFailure = lines.map { $0.hasChildren }.filter { $0 }.isEmpty
        if isOnlyTopLevelFailure {
            return [linesContents.joined()]
        } else {
            return linesContents
        }
    }

    /// Creates int value from Objective-C enum.
    private func enumIntValue<T>(for object: T) -> Int {
        withUnsafePointer(to: object) {
            $0.withMemoryRebound(to: Int.self, capacity: 1) {
                $0.pointee
            }
        }
    }
}

public enum Difference {
    /// Styling of the diff indentation.
    /// `pipe` example:
    ///     address:
    ///     |    street:
    ///     |    |    Received: 2nd Street
    ///     |    |    Expected: Times Square
    ///     |    counter:
    ///     |    |    counter:
    ///     |    |    |    Received: 1
    ///     |    |    |    Expected: 2
    /// `tab` example:
    ///     address:
    ///         street:
    ///             Received: 2nd Street
    ///             Expected: Times Square
    ///         counter:
    ///             counter:
    ///                 Received: 1
    ///                 Expected: 2
    public enum IndentationType: String, CaseIterable {
        case pipe = "|\t"
        case tab = "\t"
    }
}

private struct Line {
    let contents: String
    let indentationLevel: Int
    let children: [Line]
    let canBeOrdered: Bool

    var hasChildren: Bool { !children.isEmpty }

    init(
        contents: String,
        indentationLevel: Int,
        canBeOrdered: Bool,
        children: [Line] = []
    ) {
        self.contents = contents
        self.indentationLevel = indentationLevel
        self.children = children
        self.canBeOrdered = canBeOrdered
    }

    func generateContents(indentationType: IndentationType) -> String {
        let indentationString = indentation(level: indentationLevel, indentationType: indentationType)
        let childrenContents = children
            .sorted { lhs, rhs in
                guard lhs.canBeOrdered && rhs.canBeOrdered else { return false }
                return lhs.contents < rhs.contents
            }
            .map { $0.generateContents(indentationType: indentationType)}
            .joined()
        return "\(indentationString)\(contents)\n" + childrenContents
    }

    private func indentation(level: Int, indentationType: IndentationType) -> String {
        (0..<level).reduce("") { acc, _ in acc + "\(indentationType.rawValue)" }
    }
}

fileprivate extension String {
    init<T>(dumping object: T) {
        self.init()
        dump(object, to: &self)
        self = withoutDumpArtifacts
    }

    // Removes the artifacts of using dumping initialiser to improve readability
    private var withoutDumpArtifacts: String {
        self.replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

// In the case of an enum with an argument being compared to a different enum case,
// pull the case name from the mirror
private func enumLabelFromFirstChild(_ mirror: Mirror) -> String? {
    switch mirror.displayStyle {
    case .enum: return mirror.children.first?.label
    default: return nil
    }
}

fileprivate extension Mirror {
    func displayStyleDescriptor(index: Int) -> String {
        switch self.displayStyle {
        case .enum: return "Enum "
        case .collection: return "Collection[\(index)]"
        default: return ""
        }
    }

    // Used to show "different count" message if mirror has no children,
    // as some displayStyles can have 0 children.
    var canBeEmpty: Bool {
        switch self.displayStyle {
        case .collection,
             .dictionary,
             .set:
            return true
        default:
            return false
        }
    }

    var unwrapped: Mirror? {
        guard displayStyle == .optional else {
            return self
        }
        guard children.count != 0 else {
            return nil
        }

        let (_, value) = children.first!
        return Mirror(reflecting: value)
    }
}

/// Builds list of differences between 2 objects
///
/// - Parameters:
///   - expected: Expected value
///   - received: Received value
///   - indentationType: Style of indentation to use
///   - skipPrintingOnDiffCount: Skips the printing of the object when a collection has a different count
///
/// - Returns: List of differences
public func diff<T>(
    _ expected: T,
    _ received: T,
    indentationType: Difference.IndentationType = .pipe,
    skipPrintingOnDiffCount: Bool = false,
    nameLabels: DifferenceNameLabels = .expectation
) -> [String] {
    Differ(indentationType: indentationType, skipPrintingOnDiffCount: skipPrintingOnDiffCount, nameLabels: nameLabels)
        .diff(expected, received)
}

/// Prints list of differences between 2 objects
///
/// - Parameters:
///   - expected: Expected value
///   - received: Received value
///   - indentationType: Style of indentation to use
///   - skipPrintingOnDiffCount: Skips the printing of the object when a collection has a different count
public func dumpDiff<T: Equatable>(
    _ expected: T,
    _ received: T,
    indentationType: Difference.IndentationType = .pipe,
    skipPrintingOnDiffCount: Bool = false
) {
    // skip equal
    guard expected != received else {
        return
    }

    diff(
        expected,
        received,
        indentationType: indentationType,
        skipPrintingOnDiffCount: skipPrintingOnDiffCount
    ).forEach { print($0) }
}


/// Prints list of differences between 2 objects
///
/// - Parameters:
///   - expected: Expected value
///   - received: Received value
///   - indentationType: Style of indentation to use
///   - skipPrintingOnDiffCount: Skips the printing of the object when a collection has a different count
public func dumpDiff<T>(
    _ expected: T,
    _ received: T,
    indentationType: Difference.IndentationType = .pipe,
    skipPrintingOnDiffCount: Bool = false
) {
    diff(
        expected,
        received,
        indentationType: indentationType,
        skipPrintingOnDiffCount: skipPrintingOnDiffCount
    ).forEach { print($0) }
}
