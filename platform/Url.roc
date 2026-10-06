## Request targets: their query's values, decoded.
Url := [].{
	## The first value of `key` in the target's query, decoded as a form
	## field is (WHATWG URL, application/x-www-form-urlencoded): `+` is a
	## space and `%XX` a byte, and the bytes must be UTF-8. A key with no
	## `=` has the value "". `BadEncoding` for a `%` without two hex digits
	## after it, or bytes that are not UTF-8.
	query_value : Str, Str -> Try(Str, [NotFound, BadEncoding])
	query_value = |target, key|
		match target.split_first("?") {
			Ok({ after: query, .. }) => find(query.split_on("&"), key)
			Err(_) => Err(NotFound)
		}

	## Form decoding of one key or value.
	decode : Str -> Try(Str, [BadEncoding])
	decode = |text| {
		bytes = Str.to_utf8(text)
		start = { out: List.with_capacity(List.len(bytes)), escape: Outside, bad: Bool.False }
		{ out, escape, bad } = bytes.fold(start, decode_byte)
		if bad or escape != Outside {
			Err(BadEncoding)
		} else {
			match Str.from_utf8(out) {
				Ok(decoded) => Ok(decoded)
				Err(_) => Err(BadEncoding)
			}
		}
	}
}

find : List(Str), Str -> Try(Str, [NotFound, BadEncoding])
find = |pairs, key| {
	found = pairs.keep_oks(|pair| {
		{ name, value } =
			match pair.split_first("=") {
				Ok({ before, after }) => { name: before, value: after }
				Err(_) => { name: pair, value: "" }
			}
		match Url.decode(name) {
			Ok(decoded) if decoded == key => Ok(value)
			_ => Err(NotIt)
		}
	})
	match List.first(found) {
		Ok(value) => Url.decode(value)
		Err(_) => Err(NotFound)
	}
}

Escape : [Outside, Percent, High(U8)]

## One byte of form decoding: the record is destructured so its list is
## appended in place, not copied (the roc skill's gotchas).
decode_byte : { out : List(U8), escape : Escape, bad : Bool }, U8 -> { out : List(U8), escape : Escape, bad : Bool }
decode_byte = |{ out, escape, bad }, byte|
	match escape {
		Outside =>
			if byte == '%' {
				{ out, escape: Percent, bad }
			} else if byte == '+' {
				{ out: out.append(' '), escape: Outside, bad }
			} else {
				{ out: out.append(byte), escape: Outside, bad }
			}
		Percent =>
			match hex(byte) {
				Ok(high) => { out, escape: High(high), bad }
				Err(_) => { out, escape: Outside, bad: Bool.True }
			}
		High(high) =>
			match hex(byte) {
				Ok(low) => { out: out.append(high * 16 + low), escape: Outside, bad }
				Err(_) => { out, escape: Outside, bad: Bool.True }
			}
	}

hex : U8 -> Try(U8, [NotHex])
hex = |byte|
	if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else {
		Err(NotHex)
	}

expect Url.query_value("/sse?datastar=%7B%22count%22%3A41%7D", "datastar") == Ok("{\"count\":41}")
expect Url.query_value("/?a=1&b=two+words&b=3", "b") == Ok("two words")
expect Url.query_value("/?flag&x=1", "flag") == Ok("")
expect Url.query_value("/?caf%C3%A9=1", "café") == Ok("1")
expect Url.query_value("/?x=1", "y") == Err(NotFound)
expect Url.query_value("/nothing", "x") == Err(NotFound)
expect Url.query_value("/?x=%", "x") == Err(BadEncoding)
expect Url.query_value("/?x=%4", "x") == Err(BadEncoding)
expect Url.query_value("/?x=%zz", "x") == Err(BadEncoding)
expect Url.query_value("/?x=%FF", "x") == Err(BadEncoding)
expect Url.decode("%41%62+c") == Ok("Ab c")
