import Host
import Server

## Server-sent events: a response sent event by event as the handler
## makes them, on its connection's fiber (fourneau's streams, chunked).
##
## ```roc
## stream = Sse.start!(request, [])?
## Sse.send!(stream, Sse.Event.data("hello"))?
## Sse.end!(stream)
## ```
##
## Events made together leave together, in one write; `flush!` sends what
## waits, and belongs before any wait on something else (a sleep, another
## request), or the client waits too. A handler that returns without
## `end!` (an error, a peer that left) has its connection closed without
## the stream's end, so the client sees it cut short. Read the request's
## body before `start!`: it is not read once a stream has started.
Sse := [].{
	SseErr : [Disconnected, Refused]

	## A started stream: its request, as the host knows it.
	Stream := { request : U64 }

	## The largest event `send!` takes; larger is `Refused`.
	event_bytes_max : U64
	event_bytes_max = 64 * 1024

	## Start the stream: a 200 head with `Content-Type: text/event-stream`,
	## `Cache-Control: no-cache` and these headers. `Refused` when a header
	## could break the head (CR, LF, a name the server writes itself), or a
	## stream was started already.
	start! : Server.Request, List(Server.Header) => Try(Stream, [SseErr(SseErr)])
	start! = |request, headers| {
		all = List.concat(
			[
				{ name: "Content-Type", value: "text/event-stream" },
				{ name: "Cache-Control", value: "no-cache" },
			],
			headers,
		)
		match Host.response_stream_start!(request.body, all) {
			Ok({}) => Ok(Stream.{ request: request.body })
			Err(err) => Err(SseErr(from_host(err)))
		}
	}

	## One event, a chunk of its own.
	send! : Stream, Event => Try({}, [SseErr(SseErr)])
	send! = |Stream.{ request }, event|
		match Host.response_stream_send!(request, Event.to_bytes(event)) {
			Ok({}) => Ok({})
			Err(err) => Err(SseErr(from_host(err)))
		}

	## Send every event so far to the client now.
	flush! : Stream => Try({}, [SseErr(SseErr)])
	flush! = |Stream.{ request }|
		match Host.response_stream_flush!(request) {
			Ok({}) => Ok({})
			Err(err) => Err(SseErr(from_host(err)))
		}

	## The stream's end, and what `respond!` returns for it: the response
	## is on its way already. `Refused` after an end.
	end! : Stream => Try(Server.Response, [SseErr(SseErr)])
	end! = |Stream.{ request }|
		match Host.response_stream_end!(request) {
			Ok({}) => Ok(Server.streamed)
			Err(err) => Err(SseErr(from_host(err)))
		}

	## One event's bytes, framed (WHATWG HTML, server-sent events).
	Event := [Event(List(U8))].{
		## An event of a type (`event:`) with data: each line of the data
		## is a `data:` line, as the format carries lines (CRLF and CR are
		## line breaks too). A type with a line break would start another
		## field: refused.
		named : Str, Str -> Try(Event, [InvalidEventName])
		named = |name, data|
			if Str.contains(name, "\n") or Str.contains(name, "\r") {
				Err(InvalidEventName)
			} else {
				Ok(Event(Str.to_utf8("event: ${name}\n${data_lines(data)}\n")))
			}

		## Data alone: the client's `message` event.
		data : Str -> Event
		data = |text| Event(Str.to_utf8("${data_lines(text)}\n"))

		to_bytes : Event -> List(U8)
		to_bytes = |Event(bytes)| bytes
	}
}

from_host : [StreamDisconnected, StreamRefused] -> Sse.SseErr
from_host = |err|
	match err {
		StreamDisconnected => Disconnected
		StreamRefused => Refused
	}

## `data: ` and the line, for each line; every line ends with LF.
data_lines : Str -> Str
data_lines = |text| {
	crlf_gone = Str.join_with(text.split_on("\r\n"), "\n")
	lf = Str.join_with(crlf_gone.split_on("\r"), "\n")
	Str.join_with(lf.split_on("\n").map(|line| "data: ${line}\n"), "")
}

expect Sse.Event.to_bytes(Sse.Event.data("hi")) == Str.to_utf8("data: hi\n\n")
expect
	Sse.Event.named("patch", "a\nb").map_ok(Sse.Event.to_bytes)
	== Ok(Str.to_utf8("event: patch\ndata: a\ndata: b\n\n"))
expect Sse.Event.to_bytes(Sse.Event.data("a\r\nb\rc")) == Str.to_utf8("data: a\ndata: b\ndata: c\n\n")
expect Sse.Event.to_bytes(Sse.Event.data("")) == Str.to_utf8("data: \n\n")
expect Sse.Event.named("a\nevent: b", "x").map_ok(Sse.Event.to_bytes) == Err(InvalidEventName)
expect Sse.Event.named("a\rb", "x").map_ok(Sse.Event.to_bytes) == Err(InvalidEventName)
