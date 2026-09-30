import Foundation

enum DeepSeekPriceTier: String, Codable, Hashable, Sendable {
    case peak
    case offPeak = "off_peak"
}

enum DeepSeekCostTimeBasis: String, Codable, Hashable, Sendable {
    case start
}

struct DeepSeekCostRecord: Codable, Hashable, Sendable {
    let requestID: String
    let modelID: String
    let amountCNY: Decimal
    let priceVersion: String
    let createdAt: Date
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let outputTokens: Int?
    let startedAt: Date?
    let priceTier: DeepSeekPriceTier?
    let timeBasis: DeepSeekCostTimeBasis?

    init(
        requestID: String,
        modelID: String,
        amountCNY: Decimal,
        priceVersion: String,
        createdAt: Date,
        inputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        outputTokens: Int? = nil,
        startedAt: Date? = nil,
        priceTier: DeepSeekPriceTier? = nil,
        timeBasis: DeepSeekCostTimeBasis? = nil
    ) {
        self.requestID = requestID
        self.modelID = modelID
        self.amountCNY = amountCNY
        self.priceVersion = priceVersion
        self.createdAt = createdAt
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.startedAt = startedAt
        self.priceTier = priceTier
        self.timeBasis = timeBasis
    }
}

enum DeepSeekPricing: Sendable {
    private struct Rates: Sendable {
        let cacheReadPerMillion: Decimal
        let freshInputPerMillion: Decimal
        let outputPerMillion: Decimal
    }

    private enum ModelFamily: Sendable {
        case flash
        case pro
    }

    private static let flashRates = Rates(
        cacheReadPerMillion: Decimal(string: "0.04", locale: Locale(identifier: "en_US_POSIX"))!,
        freshInputPerMillion: Decimal(string: "2", locale: Locale(identifier: "en_US_POSIX"))!,
        outputPerMillion: Decimal(string: "8", locale: Locale(identifier: "en_US_POSIX"))!
    )
    private static let proRates = Rates(
        cacheReadPerMillion: Decimal(string: "0.30", locale: Locale(identifier: "en_US_POSIX"))!,
        freshInputPerMillion: Decimal(string: "9.0", locale: Locale(identifier: "en_US_POSIX"))!,
        outputPerMillion: Decimal(string: "27.0", locale: Locale(identifier: "en_US_POSIX"))!
    )
    private static let priceVersion = "2026-09-29"

    static func supports(baseURL: String, modelID: String) -> Bool {
        family(for: modelID) != nil && supportsBaseURL(baseURL)
    }

    static func estimate(
        modelID: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        requestID: String,
        startedAt: Date,
        endedAt: Date
    ) -> DeepSeekCostRecord? {
        guard inputTokens >= 0,
              cacheReadTokens >= 0,
              outputTokens >= 0,
              startedAt <= endedAt,
              let family = family(for: modelID),
              let timeZone = TimeZone(identifier: "Asia/Shanghai") else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // 使用 2026-09-29 价格快照；只估算已核验节假日历覆盖的 2026 年。
        guard calendar.component(.year, from: startedAt) == 2026,
              calendar.component(.year, from: endedAt) == 2026,
              let effectiveAt = effectiveDate(for: family, calendar: calendar),
              startedAt >= effectiveAt,
              !isWeekdayAdjustmentDate(calendar.dateComponents([.year, .month, .day], from: startedAt)) else {
            return nil
        }

        // 跨峰闲时按请求开始时的费率估算，并在记录中保存时间依据。
        let selectedTier: DeepSeekPriceTier = isPeak(startedAt, calendar: calendar) ? .peak : .offPeak
        let rates = rates(for: family)
        let million = Decimal(1_000_000)
        let peakMultiplier = selectedTier == .peak
            ? Decimal(1)
            : Decimal(string: "0.5", locale: Locale(identifier: "en_US_POSIX"))!
        let amount = (
            Decimal(cacheReadTokens) * rates.cacheReadPerMillion
                + Decimal(inputTokens) * rates.freshInputPerMillion
                + Decimal(outputTokens) * rates.outputPerMillion
        ) / million * peakMultiplier

        return DeepSeekCostRecord(
            requestID: requestID,
            modelID: modelID,
            amountCNY: amount,
            priceVersion: priceVersion,
            createdAt: endedAt,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            startedAt: startedAt,
            priceTier: selectedTier,
            timeBasis: .start
        )
    }

    private static func family(for modelID: String) -> ModelFamily? {
        switch modelID {
        case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            return .flash
        case "deepseek-v4-pro":
            return .pro
        default:
            return nil
        }
    }

    private static func rates(for family: ModelFamily) -> Rates {
        switch family {
        case .flash: return flashRates
        case .pro: return proRates
        }
    }

    private static func effectiveDate(for family: ModelFamily, calendar: Calendar) -> Date? {
        switch family {
        case .flash:
            return localDate(2026, 9, 10, hour: 12, calendar: calendar)
        case .pro:
            return localDate(2026, 8, 17, hour: 0, calendar: calendar)
        }
    }

    private static func localDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int,
        calendar: Calendar
    ) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }

    private static func supportsBaseURL(_ baseURL: String) -> Bool {
        guard baseURL.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !baseURL.contains("?"),
              !baseURL.contains("#"),
              !baseURL.contains("@"),
              !baseURL.contains("\\"),
              let separator = baseURL.range(of: "://") else {
            return false
        }

        let scheme = String(baseURL[..<separator.lowerBound])
        guard scheme.caseInsensitiveCompare("https") == .orderedSame else { return false }

        let remainder = baseURL[separator.upperBound...]
        let pathStart = remainder.firstIndex(of: "/")
        let authority: String
        let path: String
        if let pathStart {
            authority = String(remainder[..<pathStart])
            path = String(remainder[pathStart...])
        } else {
            authority = String(remainder)
            path = ""
        }

        let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard hostAndPort.count == 1 || hostAndPort.count == 2,
              String(hostAndPort[0]).caseInsensitiveCompare("api.deepseek.com") == .orderedSame,
              hostAndPort.count == 1 || hostAndPort[1] == "443",
              ["", "/", "/v1", "/v1/"].contains(path) else {
            return false
        }
        return true
    }

    private static func isPeak(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              (2...6).contains(weekday),
              !isLegalHoliday(components),
              let hour = components.hour,
              let minute = components.minute else {
            return false
        }
        let minuteOfDay = hour * 60 + minute
        return (9 * 60..<12 * 60).contains(minuteOfDay)
            || (14 * 60..<18 * 60).contains(minuteOfDay)
    }

    private static func isWeekdayAdjustmentDate(_ components: DateComponents) -> Bool {
        guard components.year == 2026,
              let month = components.month,
              let day = components.day else {
            return false
        }

        // 调休方案中超出法定日期的工作日休假，服务采用何种费率未核实，故不估算。
        switch month {
        case 1: return day == 2
        case 2: return day == 20 || day == 23
        case 4: return day == 6
        case 5: return day == 4 || day == 5
        case 10: return (5...7).contains(day)
        default: return false
        }
    }

    private static func isLegalHoliday(_ components: DateComponents) -> Bool {
        guard components.year == 2026,
              let month = components.month,
              let day = components.day else {
            return true
        }

        // 仅标记《全国年节及纪念日放假办法》中的 2026 法定日期；周末始终为空闲时段。
        switch month {
        case 1: return day == 1
        case 2: return (16...19).contains(day)
        case 4: return day == 5
        case 5: return (1...2).contains(day)
        case 6: return day == 19
        case 9: return day == 25
        case 10: return (1...3).contains(day)
        default: return false
        }
    }
}

struct DeepSeekBalance: Sendable, Equatable {
    let amountCNY: Decimal

    static func decode(_ data: Data) throws -> DeepSeekBalance {
        guard data.count <= 64 * 1024 else { throw DeepSeekBalanceError.responseTooLarge }
        let response = try JSONDecoder().decode(BalanceResponse.self, from: data)
        // is_available 表示能否继续推理；即使为 false，余额仍可用于展示。
        _ = response.isAvailable

        let cnyBalances = response.balanceInfos.filter { $0.currency == "CNY" }
        guard !cnyBalances.isEmpty else { throw DeepSeekBalanceError.missingCNY }
        guard cnyBalances.count == 1 else { throw DeepSeekBalanceError.duplicateCNY }
        guard let amount = parseDecimal(cnyBalances[0].totalBalance) else {
            throw DeepSeekBalanceError.invalidCNYAmount
        }
        return DeepSeekBalance(amountCNY: amount)
    }

    private static func parseDecimal(_ rawValue: String) -> Decimal? {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return nil }

        var index = 0
        if bytes[0] == 43 || bytes[0] == 45 { index = 1 }
        guard index < bytes.count else { return nil }

        var sawDecimalPoint = false
        var integerDigits = 0
        var fractionalDigits = 0
        var significantDigits = 0
        var sawNonZero = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 46 {
                guard !sawDecimalPoint else { return nil }
                sawDecimalPoint = true
            } else if (48...57).contains(byte) {
                if sawDecimalPoint {
                    fractionalDigits += 1
                } else {
                    integerDigits += 1
                }
                if byte != 48 { sawNonZero = true }
                if sawNonZero { significantDigits += 1 }
            } else {
                return nil
            }
            index += 1
        }

        guard integerDigits > 0,
              !sawDecimalPoint || fractionalDigits > 0,
              significantDigits <= 38 else {
            return nil
        }
        return Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct BalanceResponse: Decodable, Sendable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    private struct BalanceInfo: Decodable, Sendable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String?
        let toppedUpBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }
}

enum DeepSeekBalanceError: Error, Equatable, Sendable {
    case responseTooLarge
    case missingCNY
    case duplicateCNY
    case invalidCNYAmount
}
