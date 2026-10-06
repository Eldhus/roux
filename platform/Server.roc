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

	Response : {
		status : U16,
		headers : List(Header),
		body : List(U8),
	}

	BodyErr : [BodyTooLarge, BodyInvalid, BodyDisconnected]

	from_host : Host.RequestFromHost -> Request
	from_host = |request| request

	to_host : Response -> Host.ResponseToHost
	to_host = |response| response

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

	text : Str -> Response
	text = |body| {
		status: 200,
		headers: [{ name: "Content-Type", value: "text/plain; charset=utf-8" }],
		body: Str.to_utf8(body),
	}

	html : Str -> Response
	html = |body| {
		status: 200,
		headers: [{ name: "Content-Type", value: "text/html; charset=utf-8" }],
		body: Str.to_utf8(body),
	}

	status_response : U16 -> Response
	status_response = |status| { status, headers: [], body: [] }
}
