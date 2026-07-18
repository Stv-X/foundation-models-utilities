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
import Foundation
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

extension ResponsesTests {
  @Suite struct UsageReporting {
    init() { ResponsesMockSSEProtocol.reset() }

    @Test func `reports usage from response.completed event`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.textChunks(
            ["Hello"],
            usage: ResponsesMockSSE.Usage(inputTokens: 12, outputTokens: 7)
          )
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let response = try await session.respond(to: "Say hello")

      #expect(response.usage.input.totalTokenCount == 12)
      #expect(response.usage.output.totalTokenCount == 7)
    }

    @Test func `reports cached and reasoning token counts when present`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.textChunks(
            ["Done"],
            usage: ResponsesMockSSE.Usage(
              inputTokens: 30,
              outputTokens: 15,
              cachedTokens: 20,
              reasoningTokens: 4
            )
          )
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let response = try await session.respond(to: "Think carefully")

      #expect(response.usage.input.totalTokenCount == 30)
      #expect(response.usage.input.cachedTokenCount == 20)
      #expect(response.usage.output.totalTokenCount == 15)
      #expect(response.usage.output.reasoningTokenCount == 4)
    }

    @Test func `defaults cached and reasoning tokens to zero when omitted`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.textChunks(
            ["Hi"],
            usage: ResponsesMockSSE.Usage(inputTokens: 5, outputTokens: 2)
          )
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let response = try await session.respond(to: "test")

      #expect(response.usage.input.cachedTokenCount == 0)
      #expect(response.usage.output.reasoningTokenCount == 0)
    }

    @Test func `reports usage alongside streamed text`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.textChunks(
            ["Done"],
            usage: ResponsesMockSSE.Usage(inputTokens: 4, outputTokens: 1)
          )
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let response = try await session.respond(to: "ping")

      #expect(response.content == "Done")
      #expect(response.usage.input.totalTokenCount == 4)
      #expect(response.usage.output.totalTokenCount == 1)
    }
  }
}
