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
  @Suite struct ErrorHandling {
    init() { ResponsesMockSSEProtocol.reset() }

    @Test func `throws on HTTP error`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (429, Data("Rate limited".utf8))
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      await #expect(throws: (any Error).self) {
        try await session.respond(to: "test")
      }
    }

    @Test func `throws on error event embedded in SSE stream`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (200, ResponsesMockSSE.apiError(message: "Rate limit exceeded"))
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      await #expect(throws: (any Error).self) {
        try await session.respond(to: "test")
      }
    }

    @Test func `throws on response.failed event`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (200, ResponsesMockSSE.failed(message: "Model overloaded"))
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      await #expect(throws: (any Error).self) {
        try await session.respond(to: "test")
      }
    }
  }
}
