## Support for templates compiled by `rocstache-gen`: the HTML escaping every
## `{{ value }}` goes through (after its `to_str`), and formatters for
## `{{ value | name args }}`. A template imports the ones it uses in its
## `{{% %}}` block: `import pf.Rocstache exposing [plural, field]`.
Rocstache :: [].{

	## HTML-escapes `&`, `<`, `>`, `"` and `'`, for text and quoted attribute
	## values alike. Returns the input unchanged (no allocation) when nothing
	## needs escaping.
	escape : Str -> Str
	escape = |s| {
		# The output is only allocated once something needs escaping, so
		# clean text costs one scan.
		var $out = ""
		var $run_start = 0
		var $dirty = Bool.False
		var $i = 0
		for b in s.iter_utf8() {
			rep = escape_byte(b)
			if !rep.is_empty() {
				if !$dirty {
					$dirty = Bool.True
					$out = Str.with_capacity(s.count_utf8_bytes() + 32)
				}
				if $i > $run_start {
					$out = $out.concat(slice(s, $run_start, $i))
				}
				$out = $out.concat(rep)
				$run_start = $i + 1
			}
			$i = $i + 1
		}
		if !$dirty {
			s
		} else if s.count_utf8_bytes() > $run_start {
			$out.concat(s.drop_first_bytes($run_start).ok_or(""))
		} else {
			$out
		}
	}

	## ASCII uppercase.
	upper : Str -> Str
	upper = |s| s.with_ascii_uppercased()

	## ASCII lowercase.
	lower : Str -> Str
	lower = |s| s.with_ascii_lowercased()

	## At most `max_bytes` bytes, with an ellipsis when cut (never inside a
	## UTF-8 sequence): `{{ title | truncate 40 }}`.
	truncate : Str, U64 -> Str
	truncate = |s, max_bytes| {
		len = s.count_utf8_bytes()
		if len <= max_bytes {
			s
		} else {
			cut(s, len - max_bytes).concat("…")
		}
	}

	## A count with a singular or plural noun: `{{ n | plural "task" "tasks" }}`.
	## Any integer type: `{{ items | List.len | plural "item" "items" }}`.
	plural : n, Str, Str -> Str
		where [n.to_str : n -> Str]
	plural = |n, one, many| {
		text = n.to_str()
		if text == "1" "1 ${one}" else "${text} ${many}"
	}

	## Joins a list of strings: `{{ tags | join ", " }}`.
	join : List(Str), Str -> Str
	join = |items, sep| Str.join_with(items, sep)

	## `yes` or `no`.
	yes_no : Bool -> Str
	yes_no = |b| if b "yes" else "no"

	## The submitted value of form field `name`, "" when absent: refills a
	## form after a validation error. Pass the handler's `request.form!()`
	## result (or `[]` for an empty form) as the template's `form`:
	## `<input name="title" value="{{ form | field "title" }}">`.
	field : List({ name : Str, value : Str }), Str -> Str
	field = |fields, name|
		match fields.find_first(|f| f.name == name) {
			Ok(f) => f.value
			Err(_) => ""
		}

	## `selected` when form field `name` has `value` (text, or a number such
	## as an id), else "": keeps a `<select>`'s choice when the form comes
	## back. `<option value="{{ id }}" {{ ../form | selected "project_id" id }}>`.
	selected : List({ name : Str, value : Str }), Str, v -> Str
		where [v.to_str : v -> Str]
	selected = |fields, name, value| {
		text = value.to_str()
		if fields.any(|f| f.name == name and f.value == text) "selected" else ""
	}

	## The error message for form field `name`, "" when it has none:
	## `{{ errors | error_for "title" }}` next to its input, where `errors`
	## is a changeset's `errors()`.
	error_for : List({ field : Str, message : Str }), Str -> Str
	error_for = |errors, name|
		match errors.find_first(|e| e.field == name) {
			Ok(e) => e.message
			Err(_) => ""
		}

	## Percent-encodes one URL path segment or query value:
	## `<a href="/search?q={{ q | url }}">`.
	url : Str -> Str
	url = |s| percent_encode(s)
}

## Every byte but `A-Z a-z 0-9 - . _ ~` as `%XX` (RFC 3986's unreserved
## set): safe in a path segment or a query value. (Url.roc, when roux has
## it, takes this over.)
percent_encode : Str -> Str
percent_encode = |input|
	Str.from_utf8_lossy(
		Str.to_utf8(input).fold(
			[],
			|out, byte|
				if is_unreserved(byte) {
					out.append(byte)
				} else {
					out.append(37).append(hex_digit(byte // 16)).append(hex_digit(byte % 16))
				},
		),
	)

is_unreserved : U8 -> Bool
is_unreserved = |byte|
	(byte >= 48 and byte <= 57)
	or (byte >= 65 and byte <= 90)
	or (byte >= 97 and byte <= 122)
	or byte == 45
	or byte == 46
	or byte == 95
	or byte == 126

hex_digit : U8 -> U8
hex_digit = |value| if value < 10 value + 48 else value + 55

escape_byte : U8 -> Str
escape_byte = |b|
	match b {
		38 => "&amp;"
		60 => "&lt;"
		62 => "&gt;"
		34 => "&quot;"
		39 => "&#39;"
		_ => ""
	}

## Bytes `[start, end)` of `s`; both bounds are next to ASCII bytes, so on
## UTF-8 boundaries.
slice : Str, U64, U64 -> Str
slice = |s, start, end| s.drop_first_bytes(start).ok_or("").drop_last_bytes(s.count_utf8_bytes() - end).ok_or("")

## Drops at least `n` trailing bytes without splitting a UTF-8 sequence.
cut : Str, U64 -> Str
cut = |s, n|
	match s.drop_last_bytes(n) {
		Ok(t) => t
		Err(_) => if n >= s.count_utf8_bytes() "" else cut(s, n + 1)
	}

expect Rocstache.escape("plain text") == "plain text"
expect Rocstache.escape("") == ""
expect Rocstache.escape("<b>\"x\" & 'y'</b>") == "&lt;b&gt;&quot;x&quot; &amp; &#39;y&#39;&lt;/b&gt;"
expect Rocstache.escape("a<") == "a&lt;"
expect Rocstache.escape("<a") == "&lt;a"
expect Rocstache.escape("café & thé") == "café &amp; thé"
expect Rocstache.truncate("hello world", 5) == "hello…"
expect Rocstache.truncate("hello", 5) == "hello"
expect Rocstache.truncate("héllo wörld", 2) == "h…"
expect Rocstache.plural(1.I64, "task", "tasks") == "1 task"
expect Rocstache.plural(3.I64, "task", "tasks") == "3 tasks"
expect Rocstache.plural(1.U64, "task", "tasks") == "1 task"
expect Rocstache.url("a b/c&d") == "a%20b%2Fc%26d"
expect Rocstache.field([{ name: "a", value: "1" }], "a") == "1"
expect Rocstache.field([], "a") == ""
expect Rocstache.error_for([{ field: "a", message: "is required" }], "a") == "is required"
expect Rocstache.selected([{ name: "p", value: "2" }], "p", "2") == "selected"
expect Rocstache.selected([{ name: "p", value: "2" }], "p", "3") == ""
expect Rocstache.selected([{ name: "p", value: "2" }], "p", 2.I64) == "selected"
