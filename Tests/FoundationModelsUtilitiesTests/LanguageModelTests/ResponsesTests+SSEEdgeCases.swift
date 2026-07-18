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
  @Suite struct SSEEdgeCases {
    init() { ResponsesMockSSEProtocol.reset() }

    @Test func `skips SSE comment lines`() async throws {
      let sseData = Data(
        [
          ": this is a comment",
          #"data: {"type":"response.output_text.delta","delta":"Hello"}"#,
          "",
          ": another comment",
          #"data: {"type":"response.output_text.delta","delta":" World"}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "Hello World")
    }

    @Test func `handles empty lines between SSE events`() async throws {
      let sseData = Data(
        [
          #"data: {"type":"response.output_text.delta","delta":"A"}"#,
          "",
          "",
          "",
          #"data: {"type":"response.output_text.delta","delta":"B"}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "AB")
    }

    @Test func `handles DONE with leading whitespace`() async throws {
      let sseData = Data(
        [
          #"data: {"type":"response.output_text.delta","delta":"OK"}"#,
          "",
          "data:  [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "OK")
    }

    @Test func `ignores non-data SSE field lines`() async throws {
      // The `event:`/`id:`/`retry:` lines must be ignored; dispatch happens
      // on the JSON `type` field of the `data:` line.
      let sseData = Data(
        [
          "event: response.output_text.delta",
          "id: 42",
          "retry: 3000",
          #"data: {"type":"response.output_text.delta","delta":"OK"}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "OK")
    }
  }
}
