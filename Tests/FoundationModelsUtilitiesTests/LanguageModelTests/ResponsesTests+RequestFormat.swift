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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

extension ResponsesTests {
  @Suite struct RequestFormat {
    init() { ResponsesMockSSEProtocol.reset() }

    struct ProbeTool: Tool {
      let name = "probe"
      let description = "A probe tool"

      @Generable
      struct Arguments {
        var query: String
      }

      func call(arguments: Arguments) async throws -> String {
        "ok"
      }
    }

    @Test func `sends model name in request body`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeResponsesMockModel(name: "foo-mini"))
      let _ = try await session.respond(to: "test")

      let body = try responsesRequestBody()
      #expect(body["model"] as? String == "foo-mini")
    }

    @Test func `enables streaming in request`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      let body = try responsesRequestBody()
      #expect(body["stream"] as? Bool == true)
    }

    @Test func `disables server-side response storage`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      let body = try responsesRequestBody()
      #expect(body["store"] as? Bool == false)
    }

    @Test func `includes input items in request`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let model = makeResponsesMockModel()
      let instructions = Instructions { "Always respond in rhyme" }
      let session = LanguageModelSession(model: model, instructions: instructions)
      let _ = try await session.respond(to: "Hello!")

      let body = try responsesRequestBody()
      let input = try #require(body["input"] as? [[String: Any]])
      #expect(input.count >= 2)

      #expect(input.first?["role"] as? String == "system")
      #expect(input.last?["role"] as? String == "user")
    }

    @Test func `omits empty instructions entries from input`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      // A session created with tools and no instructions carries an empty
      // instructions entry. Sending it as `content: []` is rejected with a
      // 400 by strict servers (for example, Volcano Engine Ark).
      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [ProbeTool()]
      )
      let _ = try await session.respond(to: "test")

      let body = try responsesRequestBody()
      let input = try #require(body["input"] as? [[String: Any]])
      #expect(!input.contains { item in
        (item["role"] as? String) == "system"
          && ((item["content"] as? [[String: Any]])?.isEmpty ?? false)
      })
    }

    @Test func `encodes single-segment message content as a string`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "Hello!")

      let body = try responsesRequestBody()
      let input = try #require(body["input"] as? [[String: Any]])
      let userMessage = try #require(input.last { $0["role"] as? String == "user" })

      // A single-text-segment message is compacted to a plain JSON string,
      // not an array of content parts.
      #expect(userMessage["content"] is String)
      #expect(userMessage["content"] as? String == "Hello!")
    }

    @Test func `merges custom headers with defaults`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let model = makeResponsesMockModel(
        headers: ["X-Custom": "value", "Authorization": "Bearer key"]
      )
      let session = LanguageModelSession(model: model)
      let _ = try await session.respond(to: "test")

      let request = try capturedResponsesRequest()
      #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func `appends responses endpoint to base URL`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      let request = try capturedResponsesRequest()
      #expect(request.url?.path.hasSuffix("/responses") == true)
    }
  }
}
