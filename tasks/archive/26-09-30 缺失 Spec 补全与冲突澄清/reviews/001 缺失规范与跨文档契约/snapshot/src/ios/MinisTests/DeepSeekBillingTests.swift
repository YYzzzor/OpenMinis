import Foundation
import XCTest
#if canImport(Minis)
@testable import Minis
#endif

final class DeepSeekBillingTests: XCTestCase {
    func testFlashEstimateUsesExactDecimalRatesForCachedFreshAndOutputTokens() {
        let peak = estimate(
            modelID: "deepseek-flash",
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 9, 11, 10),
            end: beijingDate(2026, 9, 11, 10, 1)
        )
        XCTAssertEqual(peak?.amountCNY, Decimal(string: "0.0752"))
        XCTAssertEqual(peak?.priceVersion, "2026-09-29")
        XCTAssertEqual(peak?.inputTokens, 20_000)
        XCTAssertEqual(peak?.cacheReadTokens, 80_000)
        XCTAssertEqual(peak?.outputTokens, 4_000)
        XCTAssertEqual(peak?.startedAt, beijingDate(2026, 9, 11, 10))
        XCTAssertEqual(peak?.priceTier, .peak)
        XCTAssertEqual(peak?.timeBasis, .start)

        let offPeak = estimate(
            modelID: "deepseek-flash",
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 9, 11, 8),
            end: beijingDate(2026, 9, 11, 8, 1)
        )
        XCTAssertEqual(offPeak?.amountCNY, Decimal(string: "0.0376"))
        XCTAssertEqual(offPeak?.priceTier, .offPeak)
    }

    func testProEstimateUsesProRates() {
        let result = estimate(
            modelID: "deepseek-v4-pro",
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 8, 18, 10),
            end: beijingDate(2026, 8, 18, 10, 1)
        )
        XCTAssertEqual(result?.amountCNY, Decimal(string: "0.312"))
    }

    func testSupportsOnlyApprovedHTTPSHostsPathsAndModels() {
        for url in [
            "https://api.deepseek.com",
            "https://api.deepseek.com/",
            "https://api.deepseek.com/v1",
            "https://api.deepseek.com/v1/",
            "https://api.deepseek.com:443/v1/"
        ] {
            XCTAssertTrue(DeepSeekPricing.supports(baseURL: url, modelID: "deepseek-flash"), url)
        }

        for url in [
            "http://api.deepseek.com",
            "https://deepseek.com",
            "https://api.deepseek.com.evil.test/v1",
            "https://api.deepseek.com:444/v1",
            "https://user@api.deepseek.com/v1",
            "https://api.deepseek.com/v2",
            "https://api.deepseek.com/v1?query=1",
            "https://api.deepseek.com/v1#fragment",
            "https://api.deepseek.com:/v1"
        ] {
            XCTAssertFalse(DeepSeekPricing.supports(baseURL: url, modelID: "deepseek-flash"), url)
        }
        for modelID in ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            XCTAssertTrue(DeepSeekPricing.supports(baseURL: "https://api.deepseek.com", modelID: modelID))
        }
        XCTAssertFalse(DeepSeekPricing.supports(baseURL: "https://api.deepseek.com", modelID: "deepseek-flash-latest"))
    }

    func testRejectsInvalidCountsAndUnknownModels() {
        XCTAssertNil(estimate(inputTokens: -1))
        XCTAssertNil(estimate(cacheReadTokens: -1))
        XCTAssertNil(estimate(outputTokens: -1))
        XCTAssertNil(estimate(modelID: "unknown-model"))
    }

    func testRejectsUnknownYearsAndPrePriceHistoryAndRecordsStartBasisAcrossTariffs() {
        XCTAssertNil(estimate(start: beijingDate(2027, 9, 13, 10), end: beijingDate(2027, 9, 13, 10, 1)))
        XCTAssertNil(estimate(start: beijingDate(2026, 9, 10, 11, 59), end: beijingDate(2026, 9, 10, 12, 1)))
        let acrossPeakAndOffPeak = estimate(
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 9, 11, 11, 59),
            end: beijingDate(2026, 9, 11, 12, 1)
        )
        XCTAssertEqual(acrossPeakAndOffPeak?.amountCNY, Decimal(string: "0.0752"))
        XCTAssertEqual(acrossPeakAndOffPeak?.priceTier, .peak)
        XCTAssertEqual(acrossPeakAndOffPeak?.timeBasis, .start)
        XCTAssertNil(estimate(modelID: "deepseek-v4-pro", start: beijingDate(2026, 8, 16, 23), end: beijingDate(2026, 8, 16, 23, 1)))
        XCTAssertNil(estimate(start: beijingDate(2026, 9, 11, 10), end: beijingDate(2026, 9, 11, 9)))
    }

    func testStatutoryHolidaysAndWeekendMakeUpDaysUseOffPeakRates() {
        let result = estimate(
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 9, 25, 10),
            end: beijingDate(2026, 9, 25, 10, 1)
        )
        XCTAssertEqual(result?.amountCNY, Decimal(string: "0.0376"))

        let makeUpWeekend = estimate(
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 9, 20, 10),
            end: beijingDate(2026, 9, 20, 10, 1)
        )
        XCTAssertEqual(makeUpWeekend?.amountCNY, Decimal(string: "0.0376"))

        let nationalDay = estimate(
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 10, 1, 10),
            end: beijingDate(2026, 10, 1, 10, 1)
        )
        XCTAssertEqual(nationalDay?.amountCNY, Decimal(string: "0.0376"))

        let afterHoliday = estimate(
            inputTokens: 20_000,
            cacheReadTokens: 80_000,
            outputTokens: 4_000,
            start: beijingDate(2026, 10, 29, 10),
            end: beijingDate(2026, 10, 29, 10, 1)
        )
        XCTAssertEqual(afterHoliday?.amountCNY, Decimal(string: "0.0752"))
        XCTAssertNil(estimate(start: beijingDate(2026, 10, 6, 10), end: beijingDate(2026, 10, 6, 10, 1)))
    }

    func testBalanceSelectsCNYAndUsesTotalBalanceOnly() throws {
        let data = jsonData(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"999","granted_balance":"100","topped_up_balance":"899"},{"currency":"CNY","total_balance":"12.34","granted_balance":"1000","topped_up_balance":"2000"}]}"#)
        XCTAssertEqual(try DeepSeekBalance.decode(data).amountCNY, Decimal(string: "12.34"))
    }

    func testBalanceAcceptsZeroAndNegativeDecimalStrings() throws {
        for (raw, expected) in [("0", "0"), ("-1.25", "-1.25")] {
            let data = jsonData(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"\#(raw)"}]}"#)
            XCTAssertEqual(try DeepSeekBalance.decode(data).amountCNY, Decimal(string: expected))
        }
    }

    func testBalanceRejectsOversizedResponse() {
        let data = Data(repeating: 32, count: 64 * 1024 + 1)
        XCTAssertThrowsError(try DeepSeekBalance.decode(data)) {
            XCTAssertEqual($0 as? DeepSeekBalanceError, .responseTooLarge)
        }
    }

    func testBalanceRejectsMissingDuplicateAndMalformedCNY() {
        let missing = jsonData(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1"}]}"#)
        XCTAssertThrowsError(try DeepSeekBalance.decode(missing)) {
            XCTAssertEqual($0 as? DeepSeekBalanceError, .missingCNY)
        }

        let duplicate = jsonData(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1"},{"currency":"CNY","total_balance":"2"}]}"#)
        XCTAssertThrowsError(try DeepSeekBalance.decode(duplicate)) {
            XCTAssertEqual($0 as? DeepSeekBalanceError, .duplicateCNY)
        }

        for malformed in ["1e2", " 1.00", "1,000.00", ".5", "1.", "NaN", "1.2.3"] {
            let data = jsonData(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"\#(malformed)"}]}"#)
            XCTAssertThrowsError(try DeepSeekBalance.decode(data)) {
                XCTAssertEqual($0 as? DeepSeekBalanceError, .invalidCNYAmount, malformed)
            }
        }
    }

    private func estimate(
        modelID: String = "deepseek-flash",
        inputTokens: Int = 1,
        cacheReadTokens: Int = 0,
        outputTokens: Int = 0,
        start: Date? = nil,
        end: Date? = nil
    ) -> DeepSeekCostRecord? {
        DeepSeekPricing.estimate(
            modelID: modelID,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            requestID: "request-1",
            startedAt: start ?? beijingDate(2026, 9, 11, 10),
            endedAt: end ?? beijingDate(2026, 9, 11, 10, 1)
        )
    }

    private func jsonData(_ json: String) -> Data { Data(json.utf8) }

    private func beijingDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
