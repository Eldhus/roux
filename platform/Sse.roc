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
## Events made together leave together: they wait in the connection's
## send buffer and go out as it fills. `flush!` sends what waits, and
## belongs before any wait on something else (a sleep, another request),
## or the client waits too. A handler that returns without `end!` (an
## error, a peer that left) has its connection closed without the stream's
## end, so the client sees it cut short. Read the request's body before
## `start!`: it is not read once a stream has started.
Sse := [].{
	## `Disconnected`: the client is gone, or stopped reading for longer
	## than the server's send timeout; nothing more reaches it. `Refused`:
	## the app's mistake, an effect out of order (a second `start!`, a send
	## after `end!`), a header that could break the head, a head too large,
	## or more than 62 headers (the host holds 64, `start!`'s own two among
	## them). Never an event's size.
	SseErr : [Disconnected, Refused]

	## A started stream: its request, as the host knows it. (Not `Stream`:
	## that is the builtin effectful stream since nightly-2026-10-24.)
	Started := { request : U64 }

	## Start the stream: a 200 head with `Content-Type: text/event-stream`,
	## `Cache-Control: no-cache` and these headers. `Refused` when a header
	## could break the head (CR, LF, a name the server writes itself), the
	## head is too large, there are more than 62 headers, or a stream was
	## started already.
	start! : Server.Request, List(Server.Header) => Try(Started, [SseErr(SseErr)])
	start! = |request, headers| {
		all = List.concat(
			[
				{ name: "Content-Type", value: "text/event-stream" },
				{ name: "Cache-Control", value: "no-cache" },
			],
			headers,
		)
		match Host.response_stream_start!(request.body, all) {
			Ok({}) => Ok(Started.{ request: request.body })
			Err(err) => Err(SseErr(from_host(err)))
		}
	}

	## One event, of any size. The host frames it as it sends it, through
	## memory of a fixed size (host/sse.zig): a small event is one chunk of
	## the response, a large one several, which the client cannot tell
	## apart. A large event holds this handler until the client has taken
	## all but the send buffer's last part of it; the server answers others
	## meanwhile.
	##
	## A client acts on an event only once it has all of it, so a client
	## that leaves midway (`Disconnected`) never sees half of one. Its size
	## is the app's to bound: all of it is in memory, as the `Str` it was
	## made from, and a client receives all of it. A page drawn from data
	## that only grows (every race, every row) is bounded by what it shows,
	## not by this.
	send! : Started, Event => Try({}, [SseErr(SseErr)])
	send! = |Started.{ request }, Event({ name, data })|
		match Host.response_stream_event!(request, name, data) {
			Ok({}) => Ok({})
			Err(err) => Err(SseErr(from_host(err)))
		}

	## Send every event so far to the client now.
	flush! : Started => Try({}, [SseErr(SseErr)])
	flush! = |Started.{ request }|
		match Host.response_stream_flush!(request) {
			Ok({}) => Ok({})
			Err(err) => Err(SseErr(from_host(err)))
		}

	## The stream's end, and what `respond!` returns for it: the response
	## is on its way already. `Refused` after an end.
	end! : Started => Try(Server.Response(t), [SseErr(SseErr)])
	end! = |Started.{ request }|
		match Host.response_stream_end!(request) {
			Ok({}) => Ok(Server.streamed())
			Err(err) => Err(SseErr(from_host(err)))
		}

	## One event: its type and its data, framed as `send!` sends it
	## (WHATWG HTML, server-sent events; host/sse.zig).
	Event := [Event({ name : Str, data : Str })].{
		## An event of a type (`event:`) with data: each line of the data
		## is a `data:` line, as the format carries lines (CRLF and CR are
		## line breaks too). A type with a line break would start another
		## field: refused.
		named : Str, Str -> Try(Event, [InvalidEventName])
		named = |name, data|
			if Str.contains(name, "\n") or Str.contains(name, "\r") {
				Err(InvalidEventName)
			} else {
				Ok(Event({ name, data }))
			}

		## Data alone: the client's `message` event.
		data : Str -> Event
		data = |text| Event({ name: "", data: text })

		## The type ("" for none) and the data, for a handler's tests.
		parts : Event -> { name : Str, data : Str }
		parts = |Event(event)| event
	}
}

from_host : [StreamDisconnected, StreamRefused] -> Sse.SseErr
from_host = |err|
	match err {
		StreamDisconnected => Disconnected
		StreamRefused => Refused
	}

# The framing's cases are host/sse.zig's tests.
expect Sse.Event.parts(Sse.Event.data("hi")) == { name: "", data: "hi" }
expect
	Sse.Event.named("patch", "a\nb").map_ok(Sse.Event.parts)
	== Ok({ name: "patch", data: "a\nb" })
expect Sse.Event.named("a\nevent: b", "x").map_ok(Sse.Event.parts) == Err(InvalidEventName)
expect Sse.Event.named("a\rb", "x").map_ok(Sse.Event.parts) == Err(InvalidEventName)
