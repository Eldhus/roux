app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.Server
import pf.Sse
import pf.Url
import pf.Stdout
import pf.Sleep

## Server-sent events, and their negative space:
## - `/count?n=N`: N events, the last flushed alone after the others;
## - `/slow?n=N&ms=M`: N events, M milliseconds apart (`Sleep.millis!`,
##   the fiber parked: other requests are answered meanwhile);
## - `/large?kib=N`: one event of about 2N KiB, N KiB of short lines then
##   a line N KiB long, framed through the host's 64 KiB in pieces; then
##   `after`, to show the stream goes on;
## - `/give-up`: two events, then an error: the stream is cut short (the
##   client sees no end), and the connection closes;
## - `/body-after`: reading the body once streaming is `BodyAfterStream`,
##   reported in the stream;
## - `/send-after-end`: a send after the end is `Refused`;
## - `/no-stream`: `Server.streamed()` returned without a stream is a 500.
Context : {}

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({ config: { port: 8080, static_dir: "" }, context: {} })

respond! : Server.Request, Context => Try(Server.Response(_), [NotFound, BadRequest(Str), SseErr(Sse.SseErr), GaveUp])
respond! = |request, _context| {
	path =
		match request.target.split_first("?") {
			Ok({ before, .. }) => before
			Err(_) => request.target
		}
	match path {
		"/count" => count!(request)
		"/slow" => slow!(request)
		"/large" => large!(request)
		"/give-up" => {
			stream = Sse.start!(request, [])?
			Sse.send!(stream, Sse.Event.data("one"))?
			Sse.send!(stream, Sse.Event.data("two"))?
			Err(GaveUp)
		}
		"/body-after" => {
			stream = Sse.start!(request, [])?
			said =
				match Server.read_body!(request, 1024) {
					Ok(_) => "read"
					Err(BodyErr(err)) => Str.inspect(err)
				}
			Sse.send!(stream, Sse.Event.data(said))?
			Sse.end!(stream)
		}
		"/send-after-end" => {
			stream = Sse.start!(request, [])?
			response = Sse.end!(stream)?
			said =
				match Sse.send!(stream, Sse.Event.data("late")) {
					Ok({}) => "sent"
					Err(SseErr(err)) => Str.inspect(err)
				}
			Stdout.line!("send after end: ${said}")
			Ok(response)
		}
		"/no-stream" => Ok(Server.streamed())
		_ => Err(NotFound)
	}
}

## Bounded: at most 100 events.
count! : Server.Request => Try(Server.Response(_), [BadRequest(Str), SseErr(Sse.SseErr)])
count! = |request| {
	n =
		match Url.query_value(request.target, "n") {
			Ok(text) => U64.from_str(text) ? |_| BadRequest("n is not a number")
			Err(_) => return Err(BadRequest("no n"))
		}
	if n > 100 {
		return Err(BadRequest("n is at most 100"))
	}
	stream = Sse.start!(request, [{ name: "X-Count", value: n.to_str() }])?
	for index in 1..<n {
		Sse.send!(stream, tick(index, n))?
	}
	Sse.flush!(stream)?
	if n > 0 {
		Sse.send!(stream, tick(n, n))?
	}
	Sse.end!(stream)
}

## Bounded: at most 20 events, at most 5 s apart. Each is flushed before
## the sleep, or the client would wait for it too.
slow! : Server.Request => Try(Server.Response(_), [BadRequest(Str), SseErr(Sse.SseErr)])
slow! = |request| {
	n = number(request, "n")?
	ms = number(request, "ms")?
	if n > 20 or ms > 5_000 {
		return Err(BadRequest("n is at most 20, ms at most 5000"))
	}
	stream = Sse.start!(request, [])?
	for index in 1..=n {
		Sse.send!(stream, tick(index, n))?
		Sse.flush!(stream)?
		if index < n {
			Sleep.millis!(ms)
		}
	}
	Sse.end!(stream)
}

## Bounded: at most 16 MiB of lines, and as long a line. Each short line is
## 63 bytes and its line feed.
large! : Server.Request => Try(Server.Response(_), [BadRequest(Str), SseErr(Sse.SseErr)])
large! = |request| {
	kib = number(request, "kib")?
	if kib > 16 * 1024 {
		return Err(BadRequest("kib is at most 16384"))
	}
	lines = Str.concat("x".repeat(63), "\n").repeat(16 * kib)
	data = Str.concat(lines, "y".repeat(1024 * kib))
	event = Sse.Event.named("large", data) ? |_| BadRequest("a fixed name")
	stream = Sse.start!(request, [])?
	Sse.send!(stream, event)?
	Sse.send!(stream, Sse.Event.data("after"))?
	Sse.end!(stream)
}

## A query parameter that must be a number.
number : Server.Request, Str -> Try(U64, [BadRequest(Str)])
number = |request, name|
	match Url.query_value(request.target, name) {
		Ok(text) => U64.from_str(text).map_err(|_| BadRequest("${name} is not a number"))
		Err(_) => Err(BadRequest("no ${name}"))
	}

## Event `index` of `n`: data alone, the client's `message` event.
tick : U64, U64 -> Sse.Event
tick = |index, n| Sse.Event.data("tick ${index.to_str()} of ${n.to_str()}")
