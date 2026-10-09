import Host

## Requests, responses and the server's configuration.
Server := [].{
	## `static_dir`: a directory whose files the host serves itself, before
	## `respond!` (gzip copies, ETags, ranges: fourneau's site.zig), at the
	## root of the URL space; "" for none. Relative to the working directory.
	Config : { port : U16, static_dir : Str }

	Header : { name : Str, value : Str }

	Request : {
		method : Str,
		target : Str,
		headers : List(Header),
		body : U64,
	}

	## `t` is the app's templates' union (`Templates.Template`, generated),
	## which the host renders as the response is sent. Apps write
	## `Server.Response(_)`: the generated constructors pin it.
	Response(t) : {
		status : U16,
		headers : List(Header),
		body : Body(t),
	}

	## `Html`: a template's value as its generated `X.template` makes it
	## (`Rocstache.Template`), rendered as it is sent.
	Body(t) : [Bytes(List(U8)), Text(Str), Html({ layouts : U64, template : t })]

	## `BodyAfterStream`: read after `Sse.start!`, when it no longer can be.
	## `BodyDuringWrite`: read while the request holds the database's
	## writer (`Sqlite.write!`), which would wait on the client with every
	## other writer waiting too: read the body first.
	BodyErr : [BodyTooLarge, BodyInvalid, BodyDisconnected, BodyAfterStream, BodyDuringWrite]

	from_host : Host.RequestFromHost -> Request
	from_host = |request| request

	## The response as the host takes it: a template is rendered now, from
	## the union as Roc laid it out (the box goes back to Roc to release).
	to_host! : Response(t) => Host.ResponseToHost
	to_host! = |{ status, headers, body }| {
		status,
		headers,
		body: match body {
			Bytes(bytes) => bytes
			Text(text) => Str.to_utf8(text)
			Html(made) => Host.template_render!(made.layouts, Box.box(made.template)).bytes
		},
	}

	## The request body, up to `limit_bytes` (413 beyond it is the app's
	## to answer). Read from the network only when called.
	read_body! : Request, U64 => Try(List(U8), [BodyErr(BodyErr)])
	read_body! = |request, limit_bytes|
		match Host.request_body_read_all!(request.body, limit_bytes) {
			Ok(bytes) => Ok(bytes)
			Err(err) => Err(BodyErr(err))
		}

	## The value of the first header with this name (any case).
	header : Request, Str -> Try(Str, [NotFound])
	header = |request, name| {
		match List.find_first(request.headers, |h| h.name.caseless_ascii_equals(name)) {
			Ok(found) => Ok(found.value)
			Err(_) => Err(NotFound)
		}
	}

	text : Str -> Response(t)
	text = |body| {
		status: 200,
		headers: [{ name: "Content-Type", value: "text/plain; charset=utf-8" }],
		body: Text(body),
	}

	status_response : U16 -> Response(t)
	status_response = |status| { status, headers: [], body: Bytes([]) }

	## What `respond!` returns after a stream (`Sse.end!` gives it): the
	## response is on its way already. Returned without a stream, the host
	## answers 500: status 0 is no status.
	streamed : Response(t)
	streamed = { status: 0, headers: [], body: Bytes([]) }
}
