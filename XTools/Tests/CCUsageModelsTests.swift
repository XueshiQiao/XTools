import XCTest

final class CCUsageModelsTests: XCTestCase {

    func testDecodeAndAggregations() throws {
        let sampleJSON = """
        {
          "daily": [
            {
              "agent": "all",
              "period": "2026-10-17",
              "inputTokens": 971111,
              "outputTokens": 999041,
              "cacheCreationTokens": 3846738,
              "cacheReadTokens": 144437253,
              "totalTokens": 150260143,
              "totalCost": 83.10199,
              "modelsUsed": ["claude-opus-5-5", "gemini-3.8-flash-low"],
              "modelBreakdowns": [
                {
                  "modelName": "claude-opus-5-5",
                  "inputTokens": 3566,
                  "outputTokens": 964326,
                  "cacheCreationTokens": 3846738,
                  "cacheReadTokens": 134531513,
                  "cost": 82.96
                },
                {
                  "modelName": "gemini-3.8-flash-low",
                  "inputTokens": 967545,
                  "outputTokens": 34715,
                  "cacheCreationTokens": 0,
                  "cacheReadTokens": 9905740,
                  "cost": 0.14199
                }
              ],
              "agents": [
                {
                  "agent": "claude",
                  "inputTokens": 3566,
                  "outputTokens": 964326,
                  "cacheCreationTokens": 3846738,
                  "cacheReadTokens": 134531513,
                  "totalTokens": 139346143,
                  "totalCost": 82.96,
                  "modelsUsed": ["claude-opus-5-5"]
                },
                {
                  "agent": "antigravity",
                  "inputTokens": 967545,
                  "outputTokens": 34715,
                  "cacheCreationTokens": 0,
                  "cacheReadTokens": 9905740,
                  "totalTokens": 10914000,
                  "totalCost": 0.14199,
                  "modelsUsed": ["gemini-3.8-flash-low"]
                }
              ]
            },
            {
              "agent": "all",
              "period": "2026-10-18",
              "inputTokens": 2167313,
              "outputTokens": 1863016,
              "cacheCreationTokens": 18848363,
              "cacheReadTokens": 370217499,
              "totalTokens": 393130163,
              "totalCost": 219.4913,
              "modelsUsed": ["claude-opus-5-5"],
              "modelBreakdowns": [],
              "agents": []
            }
          ],
          "totals": {
            "inputTokens": 3138424,
            "outputTokens": 2862057,
            "cacheCreationTokens": 22695101,
            "cacheReadTokens": 514654752,
            "totalTokens": 543390306,
            "totalCost": 302.59329,
            "unpricedModels": ["model_placeholder_m418"]
          }
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(CCUsageReport.self, from: sampleJSON)
        XCTAssertEqual(report.daily.count, 2)
        XCTAssertEqual(report.dailyNewestFirst.first?.period, "2026-10-18")
        XCTAssertEqual(report.totals.totalTokens, 543390306)
        XCTAssertEqual(report.totals.unpricedModels, ["model_placeholder_m418"])

        let oct17 = try XCTUnwrap(report.entry(for: "2026-10-17"))
        XCTAssertEqual(oct17.shortDateLabel, "10-17")
        XCTAssertEqual(oct17.sortedAgents.first?.displayName, "Claude")
        XCTAssertEqual(oct17.sortedModels.first?.modelName, "claude-opus-5-5")

        XCTAssertEqual(CCFormat.cost(219.4913), "$219.49")
        XCTAssertEqual(CCFormat.compactTokens(393_130_163), "393.1M")
        XCTAssertEqual(CCFormat.compactTokens(3_139_297_314), "3.14B")
    }
}
