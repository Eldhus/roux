import Host

## Waiting on the request's fiber, not its thread: the shard serves other
## connections meanwhile (fourneau's Evented `Io`, an io_uring timeout).
## For a stream that follows the database by polling it (a Datastar page
## asking every second or two what changed), or a deliberate delay.
##
## ```roc
## stream = Sse.start!(request, [])?
## for _ in List.range(0, 3_600) {
##     Sse.send!(stream, Rocstache.patch!(Clock.template({ now: now!(db, request)? })))?
##     Sse.flush!(stream)?
##     Sleep.millis!(1_000)
## }
## Sse.end!(stream)
## ```
##
## Flush before sleeping, or the client waits too (Sse). A client that left
## is found at the next send (`Disconnected`), so a stream that sleeps
## between sends notices within one sleep.
Sleep := [].{
	## Waits `milliseconds`, at most a day (a longer wait is a day).
	millis! : U64 => {}
	millis! = |milliseconds| Host.sleep_millis!(milliseconds)
}
