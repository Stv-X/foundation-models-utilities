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
  @Suite struct Reasoning {
    init() { ResponsesMockSSEProtocol.reset() }

    @Test func `forwards reasoning_summary_text deltas as a reasoning transcript entry`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.reasoningAndText(
            reasoningChunks: ["Let me think", " about this..."],
            textChunks: ["The answer is 42."]
          )
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "What is the answer?")

      let reasoningEntries = session.transcript.compactMap(\.reasoning)
      #expect(reasoningEntries.count == 1)

      let reasoningText =
        reasoningEntries.first?.segments.compactMap { segment -> String? in
          if case .text(let text) = segment { return text.content }
          return nil
        }.joined() ?? ""
      #expect(reasoningText == "Let me think about this...")

      #expect(session.transcript.responseText == "The answer is 42.")
    }

    @Test func `interleaves reasoning and content deltas`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.events([
            (
              "response.reasoning_summary_text.delta",
              ["delta": "First ", "item_id": "rs_1"]
            ),
            (
              "response.output_text.delta",
              ["delta": "Hello", "item_id": "msg_1"]
            ),
            (
              "response.reasoning_summary_text.delta",
              ["delta": "thought", "item_id": "rs_1"]
            ),
            (
              "response.output_text.delta",
              ["delta": " world", "item_id": "msg_1"]
            ),
            (
              "response.completed",
              ["response": ["status": "completed", "usage": NSNull()]]
            ),
          ])
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      let reasoningEntries = session.transcript.compactMap(\.reasoning)
      #expect(reasoningEntries.count == 1)
      let reasoningText =
        reasoningEntries
        .flatMap(\.segments)
        .compactMap { segment -> String? in
          if case .text(let text) = segment { return text.content }
          return nil
        }
        .joined()
      #expect(reasoningText == "First thought")

      let responseEntries = session.transcript.compactMap(\.response)
      #expect(responseEntries.count == 1)
      #expect(session.transcript.responseText == "Hello world")
    }

    @Test func `echoes prior reasoning back as a reasoning input item`() async throws {
      // Round 1: model emits reasoning + response.
      // Round 2: send a follow-up; verify the prior reasoning is echoed
      // back as a `reasoning` input item with its summary text.
      var roundCount = 0
      ResponsesMockSSEProtocol.handler = { _ in
        defer { roundCount += 1 }
        if roundCount == 0 {
          return (
            200,
            ResponsesMockSSE.reasoningAndText(
              reasoningChunks: ["Carefully considering"],
              textChunks: ["First answer"]
            )
          )
        } else {
          return (200, ResponsesMockSSE.text("Second answer"))
        }
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "First question")
      let _ = try await session.respond(to: "Follow up")

      let body = try responsesRequestBody()
      let input = try #require(body["input"] as? [[String: Any]])
      let reasoningItem = try #require(
        input.first { $0["type"] as? String == "reasoning" }
      )
      let summary = try #require(reasoningItem["summary"] as? [[String: Any]])
      let text = try #require(summary.first?["text"] as? String)
      #expect(text == "Carefully considering")
    }

    @Test func `forwards reasoning_text deltas as a reasoning transcript entry`() async throws {
      // Some reasoning models emit `response.reasoning_text.delta` (the
      // payload type behind the `response.reasoning.delta` SSE event)
      // instead of `reasoning_summary_text.delta`. Both should feed the same
      // reasoning entry.
      ResponsesMockSSEProtocol.handler = { _ in
        (
          200,
          ResponsesMockSSE.events([
            (
              "response.reasoning_text.delta",
              ["delta": "Pondering", "item_id": "rs_1"]
            ),
            (
              "response.output_text.delta",
              ["delta": "Done", "item_id": "msg_1"]
            ),
            (
              "response.completed",
              ["response": ["status": "completed", "usage": NSNull()]]
            ),
          ])
        )
      }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      let reasoningEntries = session.transcript.compactMap(\.reasoning)
      #expect(reasoningEntries.count == 1)
      let reasoningText =
        reasoningEntries.first?.segments.compactMap { segment -> String? in
          if case .text(let text) = segment { return text.content }
          return nil
        }.joined() ?? ""
      #expect(reasoningText == "Pondering")
    }
  }
}
