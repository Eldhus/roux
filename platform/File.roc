import Host

## Files on the server's disk, read whole. Each read waits on its
## connection's fiber, not the thread.
File := [].{
	FileErr : [FileNotFound, FileTooLarge, FileUnreadable]

	## The file as text, at most `limit_bytes` (larger is `FileTooLarge`;
	## bytes that are not UTF-8 are `FileUnreadable`). A path is relative to
	## the working directory.
	read_utf8! : Str, U64 => Try(Str, [FileErr(FileErr)])
	read_utf8! = |path, limit_bytes|
		match Host.file_read_utf8!(path, limit_bytes) {
			Ok(text) => Ok(text)
			Err(err) => Err(FileErr(err))
		}
}
