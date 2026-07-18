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
  @Suite struct TextResponse {
    init() { ResponsesMockSSEProtocol.reset() }

    @Test func `generates text from streamed SSE events`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (200, ResponsesMockSSE.text("Hello", " world", "!"))
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "Say hello")

      let responseText = session.transcript.responseText
      #expect(responseText == "Hello world!")
    }

    @Test func `handles multi-turn conversation`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (200, ResponsesMockSSE.text("Response"))
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "first")
      let _ = try await session.respond(to: "second")

      let prompts = session.transcript.compactMap(\.prompt)
      #expect(prompts.count == 2)
    }
  }
}
