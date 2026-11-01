app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.Server
import pf.Stdout
import pf.Rocstache
import templates/Numbers
import templates/Holes

## A check, not a server: the renderer prints an integer itself when a
## hole is only its path's `.to_str()`, and this app checks it prints what
## Roc's `to_str` does. `templates/Numbers.rocstache` prints each number
## twice, by the renderer and by Roc; `init!` compares the two on every
## line and exits, 0 when all agree. The numbers: every width's edges (its
## least and greatest, either side of each power of two and of ten), then
## `count` from a generator seeded by `seed`.
##
##     roux build main.roc && ./main

Context : {}

program = { init!, respond!, hole: Holes.hole }

seed : U64
seed = 20261101

count : U64
count = 2000

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || {
	numbers = edges().concat(random(seed, count))
	page = Rocstache.str!(Numbers.template({ rows: numbers.map(row) }))
	lines = page.split_on("\n").keep_if(|line| line != "")
	wrong = lines.keep_if(|line| !agrees(line))
	for line in wrong.take_first(10) {
		Stdout.line!("differs: ${line}")
	}
	checked = "${lines.len().to_str()} numbers (seed ${seed.to_str()})"
	if wrong.is_empty() and lines.len() == numbers.len() * 8 {
		Stdout.line!("${checked}: the renderer prints each as Roc does")
		Err(Exit(0))
	} else {
		Stdout.line!("${checked}: ${wrong.len().to_str()} differ")
		Err(Exit(1))
	}
}

respond! : Server.Request, Context => Try(Server.Response(_), [NotFound])
respond! = |_request, _context| Err(NotFound)

## Its two halves, the renderer's and Roc's, the same.
agrees : Str -> Bool
agrees = |line|
	match line.split_first(" ") {
		Ok({ before, after }) => before == after
		Err(NotFound) => False
	}

## One number in every width, wrapped: so 2^7 is I8's least, 2^64 - 1 is
## U64's greatest and I64's -1.
row : U64 -> { u8 : U8, u16 : U16, u32 : U32, u64 : U64, i8 : I8, i16 : I16, i32 : I32, i64 : I64 }
row = |n| {
	u8: n.to_u8_wrap(),
	u16: n.to_u16_wrap(),
	u32: n.to_u32_wrap(),
	u64: n,
	i8: n.to_i8_wrap(),
	i16: n.to_i16_wrap(),
	i32: n.to_i32_wrap(),
	i64: n.to_i64_wrap(),
}

## Each power of two where a width ends or its sign starts, and each power
## of ten, with its neighbours.
edges : () -> List(U64)
edges = || {
	twos : List(U64)
	twos = [128, 256, 32768, 65536, 2147483648, 4294967296, 9223372036854775808]
	var $tens = []
	var $ten = 1.U64
	for _ in 0..<19 {
		$ten = $ten * 10
		$tens = $tens.append($ten)
	}
	var $out = [0, 1, 2, 9, 18446744073709551615]
	for power in twos.concat($tens) {
		$out = $out.concat([power.minus_wrap(1), power, power.plus_wrap(1)])
	}
	$out
}

## `n` numbers from a linear congruential generator, each shifted right by
## a second draw, so every count of digits comes up.
random : U64, U64 -> List(U64)
random = |start, n| {
	var $state = start
	var $out = []
	for _ in 0..<n {
		$state = $state.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
		value = $state
		$state = $state.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
		shift = $state.shr_zf_wrap(58).to_u8_wrap()
		$out = $out.append(value.shr_zf_wrap(shift))
	}
	$out
}
