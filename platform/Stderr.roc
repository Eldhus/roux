import Host

## The process's standard error.
Stderr := [].{
	## Write a line to standard error.
	line! : Str => {}
	line! = |message| Host.stderr_line!(message)
}
