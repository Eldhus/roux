import Host

## The process's standard output.
Stdout := [].{
	## Write a line to standard output.
	line! : Str => {}
	line! = |message| Host.stdout_line!(message)
}
