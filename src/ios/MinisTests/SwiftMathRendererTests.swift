import XCTest
import UIKit
@testable import Minis

@MainActor
final class SwiftMathRendererTests: XCTestCase {

    func testFallbackAppliesSingleCharacterSubscriptAndSuperscript() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(latex: "x_i^2", fontSize: 20)
        )

        XCTAssertEqual(rendered.string, "xi2")
        XCTAssertLessThan(baselineOffset(in: rendered, at: 1), 0)
        XCTAssertGreaterThan(baselineOffset(in: rendered, at: 2), 0)
        XCTAssertLessThan(fontSize(in: rendered, at: 1), fontSize(in: rendered, at: 0))
        XCTAssertLessThan(fontSize(in: rendered, at: 2), fontSize(in: rendered, at: 0))
    }

    func testFallbackAppliesGroupedSubscriptAndSuperscript() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(latex: "a_{ij}^{10}", fontSize: 20)
        )

        XCTAssertEqual(rendered.string, "aij10")
        XCTAssertLessThan(baselineOffset(in: rendered, at: 1), 0)
        XCTAssertLessThan(baselineOffset(in: rendered, at: 2), 0)
        XCTAssertGreaterThan(baselineOffset(in: rendered, at: 3), 0)
        XCTAssertGreaterThan(baselineOffset(in: rendered, at: 4), 0)
    }

    func testFallbackKeepsEscapedScriptMarkersLiteral() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(latex: #"x\_label \^ caret"#, fontSize: 20)
        )

        XCTAssertEqual(rendered.string, "x_label ^ caret")
        XCTAssertEqual(baselineOffset(in: rendered, at: 1), 0)
        XCTAssertEqual(baselineOffset(in: rendered, at: 8), 0)
    }

    func testFallbackConsumesEmptyAndTrailingScriptMarkers() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(latex: "x^{}y_", fontSize: 20)
        )

        XCTAssertEqual(rendered.string, "xy")
    }

    func testFallbackKeepsCommandGroupAndEscapedLiteralsInScript() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(
                latex: #"x^\text{hi}_{a\_b\{c\}}"#,
                fontSize: 20
            )
        )

        XCTAssertEqual(rendered.string, "xhia_b{c}")
        XCTAssertGreaterThan(baselineOffset(in: rendered, at: 1), 0)
        XCTAssertGreaterThan(baselineOffset(in: rendered, at: 2), 0)
        for index in 3..<rendered.length {
            XCTAssertLessThan(baselineOffset(in: rendered, at: index), 0)
        }
    }

    func testFallbackKeepsTextCommandMarkersLiteral() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(
                latex: #"\text{snake_case a^b}"#,
                fontSize: 20
            )
        )

        XCTAssertEqual(rendered.string, "snake_case a^b")
        for index in 0..<rendered.length {
            XCTAssertEqual(baselineOffset(in: rendered, at: index), 0)
        }
    }

    func testFallbackSupportsEscapedLiteralAsSingleScriptOperand() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(latex: #"x_\_y^\^"#, fontSize: 20)
        )

        XCTAssertEqual(rendered.string, "x_y^")
        XCTAssertLessThan(baselineOffset(in: rendered, at: 1), 0)
        XCTAssertGreaterThan(baselineOffset(in: rendered, at: 3), 0)
    }

    func testFallbackKeepsTextCommandsInsideFractionAndSquareRoot() throws {
        let fraction = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(
                latex: #"\frac{\text{a}}{\text{b}}"#,
                fontSize: 20
            )
        )
        let squareRoot = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(
                latex: #"\sqrt{\text{a}+1}"#,
                fontSize: 20
            )
        )

        XCTAssertEqual(fraction.string, "a/b")
        XCTAssertEqual(squareRoot.string, "√(a+1)")
    }

    func testFallbackConsumesNestedScriptMarkers() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(latex: "e^{x^2}+x^{a_b}", fontSize: 20)
        )

        XCTAssertEqual(rendered.string, "ex2+xab")
        XCTAssertFalse(rendered.string.contains("^"))
        XCTAssertFalse(rendered.string.contains("_"))
    }

    func testFallbackSkipsWhitespaceBeforeScriptOperand() throws {
        let rendered = try XCTUnwrap(
            SwiftMathRenderer.fallbackAttributedString(latex: "x^ 2+y_ 1", fontSize: 20)
        )

        XCTAssertEqual(rendered.string, "x2+y1")
        XCTAssertGreaterThan(baselineOffset(in: rendered, at: 1), 0)
        XCTAssertLessThan(baselineOffset(in: rendered, at: 4), 0)
    }

    func testFallbackRendererProducesUnclippedImageForScripts() throws {
        let result = try XCTUnwrap(SwiftMathRenderer.renderFallback(
            latex: "E_{n}^{(2)}",
            displayMode: false,
            fontSize: 20
        ))

        XCTAssertGreaterThan(result.size.width, 0)
        XCTAssertGreaterThan(result.size.height, 0)
        let alpha = try alphaSummary(of: result.image)
        XCTAssertTrue(alpha.hasContent)
        XCTAssertFalse(alpha.touchesBorder)

        let largeResult = try XCTUnwrap(SwiftMathRenderer.renderFallback(
            latex: "E_{gggg}^{MMMM}",
            displayMode: false,
            fontSize: 80
        ))
        let largeAlpha = try alphaSummary(of: largeResult.image)
        XCTAssertTrue(largeAlpha.hasContent)
        XCTAssertFalse(largeAlpha.touchesBorder)
    }

    private func baselineOffset(in string: NSAttributedString, at index: Int) -> CGFloat {
        (string.attribute(.baselineOffset, at: index, effectiveRange: nil) as? NSNumber)
            .map(CGFloat.init(truncating:)) ?? 0
    }

    private func fontSize(in string: NSAttributedString, at index: Int) -> CGFloat {
        (string.attribute(.font, at: index, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
    }

    private func alphaSummary(of image: UIImage) throws -> (hasContent: Bool, touchesBorder: Bool) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let data = buffer.baseAddress,
                  let context = CGContext(
                    data: data,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(rendered)

        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * width + x) * 4 + 3]
        }
        var hasContent = false
        var touchesBorder = false
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 0 {
                hasContent = true
                if x == 0 || x == width - 1 || y == 0 || y == height - 1 {
                    touchesBorder = true
                }
            }
        }
        return (hasContent, touchesBorder)
    }
}
