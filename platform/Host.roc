## The host's effects and the records that cross the boundary. Apps use
## them through Server, Stdout and Stderr, never directly.
Host := [].{
	Header : { name : Str, value : Str }

	RequestFromHost : {
		method : Str,
		target : Str,
		headers : List(Header),
		## Names this request's body to `request_body_read_all!`.
		body : U64,
	}

	ResponseToHost : {
		status : U16,
		headers : List(Header),
		body : List(U8),
	}

	stdout_line! : Str => {}
	stderr_line! : Str => {}

	## The whole body, up to `limit_bytes`; read from the connection only
	## now, when the handler asks.
	request_body_read_all! : U64, U64 => Try(List(U8), [BodyTooLarge, BodyInvalid, BodyDisconnected])
}
