//
//  CodeSignKitTests.swift
//  CodeSignKit
//
//  Non-invasive static verification — does not invoke codesign or re-exec.
//

import CodeSignKit
import XCTest

final class CodeSignKitTests: XCTestCase {
    func testSignMainExecutableOnceAndRunSymbolIsPresent() {
        // Compile-time/link-time API presence check only.
        let symbol = CodeSign.signMainExecutableOnceAndRun
        XCTAssertNotNil(symbol)
    }

    func testSignSymbolIsPresent() {
        let symbol = CodeSign.sign
        XCTAssertNotNil(symbol)
    }
}
