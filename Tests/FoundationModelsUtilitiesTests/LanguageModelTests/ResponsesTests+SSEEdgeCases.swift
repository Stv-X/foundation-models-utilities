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

    @Test func `parses data fields without a space after the colon`() async throws {
      let sseData = Data(
        [
          #"data:{"type":"response.output_text.delta","delta":"OK"}"#,
          "",
          "data:[DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "OK")
    }

    @Test func `tolerates CRLF line endings`() async throws {
      let sseData = Data(
        [
          #"data: {"type":"response.output_text.delta","delta":"OK"}"#
            + "\r\n",
          "\r\n",
          "data: [DONE]\r\n",
          "\r\n",
        ].joined().utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "OK")
    }

    @Test func `joins multi-line data fields into one event`() async throws {
      // A single event's JSON split across consecutive `data:` fields must
      // reassemble (joined with "\n") before decoding.
      let sseData = Data(
        [
          "data: {",
          #"data: "type":"response.output_text.delta","delta":"OK""#,
          "data: }",
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

    @Test func `dispatches a trailing event without a blank line`() async throws {
      // The stream ends without the terminating blank line; the parser must
      // still dispatch the pending event.
      let sseData = Data(
        [
          #"data: {"type":"response.output_text.delta","delta":"OK"}"#
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "OK")
    }

    @Test func `uses terminal text when the server sends no deltas`() async throws {
      let sseData = Data(
        [
          #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","status":"in_progress","content":[]}}"#,
          "",
          #"data: {"type":"response.output_text.done","item_id":"msg_1","output_index":0,"text":"Hello there"}"#,
          "",
          #"data: {"type":"response.completed","response":{"status":"completed","usage":null}}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "Hello there")
    }

    @Test func `does not duplicate text when deltas and terminal text both arrive`() async throws {
      let sseData = Data(
        [
          #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","status":"in_progress","content":[]}}"#,
          "",
          #"data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"Hel"}"#,
          "",
          #"data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"lo"}"#,
          "",
          #"data: {"type":"response.output_text.done","item_id":"msg_1","output_index":0,"text":"Hello"}"#,
          "",
          #"data: {"type":"response.completed","response":{"status":"completed","usage":null}}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "Hello")
    }

    @Test func `streams refusal deltas as response text`() async throws {
      let sseData = Data(
        [
          #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","status":"in_progress","content":[]}}"#,
          "",
          #"data: {"type":"response.refusal.delta","item_id":"msg_1","output_index":0,"delta":"I cannot"}"#,
          "",
          #"data: {"type":"response.refusal.done","item_id":"msg_1","output_index":0,"refusal":"I cannot help with that"}"#,
          "",
          #"data: {"type":"response.completed","response":{"status":"completed","usage":null}}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      // Deltas stream; the terminal refusal is deduplicated.
      #expect(session.transcript.responseText == "I cannot")
    }

    @Test func `uses terminal refusal when the server sends no refusal deltas`() async throws {
      let sseData = Data(
        [
          #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","status":"in_progress","content":[]}}"#,
          "",
          #"data: {"type":"response.refusal.done","item_id":"msg_1","output_index":0,"refusal":"I cannot help with that"}"#,
          "",
          #"data: {"type":"response.completed","response":{"status":"completed","usage":null}}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeResponsesMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "I cannot help with that")
    }
  }
}
