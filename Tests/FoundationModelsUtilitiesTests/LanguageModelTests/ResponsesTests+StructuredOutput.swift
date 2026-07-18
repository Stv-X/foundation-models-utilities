//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
#if canImport(Darwin)
import Foundation
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

extension ResponsesTests {
  @Suite struct StructuredOutput {
    init() { ResponsesMockSSEProtocol.reset() }

    @Generable
    struct MockWeatherInfo {
      var temperature: Int
      var condition: String
    }

    @Test func `parses structured JSON response into Generable type`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.text(
            #"{"temperature":"#,
            #"72,"#,
            #""condition":"#,
            #""sunny"}"#
          )
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let response = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self
      )

      #expect(response.content.temperature == 72)
      #expect(response.content.condition == "sunny")
    }

    @Test func `includes text format in request for structured output`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (200, ResponsesMockSSE.text(#"{"temperature":65,"condition":"cloudy"}"#))
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self
      )

      let body = try responsesRequestBody()
      let text = try #require(body["text"] as? [String: Any])
      let format = try #require(text["format"] as? [String: Any])
      #expect(format["type"] as? String == "json_schema")
      #expect(format["name"] != nil)
      #expect(format["strict"] as? Bool == true)
    }

    @Test func `omits text format when no schema is requested`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      let body = try responsesRequestBody()
      #expect(body["text"] == nil)
    }

    @Test func `parses structured output from single-character chunks`() async throws {
      let json = #"{"temperature":99,"condition":"hot"}"#

      ResponsesMockSSEProtocol.handler = { _ in
        (200, ResponsesMockSSE.textChunks(json.map { String($0) }))
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let response = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self
      )

      #expect(response.content.temperature == 99)
      #expect(response.content.condition == "hot")
    }
  }
}
#endif
