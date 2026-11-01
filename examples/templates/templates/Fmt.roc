## The page's own Roc for its holes: plain functions, tested like any other.
Fmt :: [].{
	## A count and the noun that fits it: `1 dish`, `3 dishes`.
	plural : U64, Str, Str -> Str
	plural = |count, one, many| {
		noun = if count == 1 one else many
		"${count.to_str()} ${noun}"
	}
}

expect Fmt.plural(1, "dish", "dishes") == "1 dish"
expect Fmt.plural(0, "dish", "dishes") == "0 dishes"
expect Fmt.plural(3, "dish", "dishes") == "3 dishes"
