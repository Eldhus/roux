platform "roux"
	requires {
		[Context : context] for program : {
			init! : () => Try({ config : Server.Config, context : context }, [Exit(I64), ..]),
			respond! : Server.Request, context => Try(Server.Response, _err),
		}
	}
	exposes [Server, Stdout, Stderr, Rocstache, File, Sse, Url, Sqlite]
	packages {}
	provides {
		"roc_init_for_host": init_for_host!,
		"roc_respond_for_host": respond_for_host!,
	}
	hosted {
		"hosted_stdout_line": Host.stdout_line!,
		"hosted_stderr_line": Host.stderr_line!,
		"hosted_file_read_utf8": Host.file_read_utf8!,
		"hosted_request_body_read_all": Host.request_body_read_all!,
		"hosted_response_stream_start": Host.response_stream_start!,
		"hosted_response_stream_send": Host.response_stream_send!,
		"hosted_response_stream_flush": Host.response_stream_flush!,
		"hosted_response_stream_end": Host.response_stream_end!,
		"hosted_sqlite_open": Host.sqlite_open!,
		"hosted_sqlite_run": Host.sqlite_run!,
		"hosted_sqlite_write_begin": Host.sqlite_write_begin!,
		"hosted_sqlite_commit": Host.sqlite_commit!,
	}
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Host
import Server
import Stdout
import Stderr
import Rocstache
import File
import Sse
import Url
import Sqlite

## Called once, before the listener opens: the app's configuration and its
## immutable context, which every handler on every fiber shares.
init_for_host! : () => Try({ port : U16, static_dir : Str, context : Box(Context) }, I64)
init_for_host! = ||
	match (program.init!)() {
		Ok({ config, context }) => Ok({ port: config.port, static_dir: config.static_dir, context: Box.box(context) })
		Err(Exit(code)) => Err(code)
		Err(other) => {
			Stderr.line!("ERROR init!: ${Str.inspect(other)}")
			Err(1)
		}
	}

## Called on the request's own fiber; it may block in effects, which yield
## the fiber rather than a thread.
respond_for_host! : Host.RequestFromHost, Box(Context) => Host.ResponseToHost
respond_for_host! = |request, boxed_context| {
	context = Box.unbox(boxed_context)
	match (program.respond!)(Server.from_host(request), context) {
		Ok(response) => Server.to_host(response)
		Err(err) => {
			inspected = Str.inspect(err)
			status = error_status(inspected)
			Stderr.line!("${if status == 500 "ERROR" else "WARN"} respond! ${request.method} ${request.target}: ${inspected}")
			Server.to_host(Server.status_response(status))
		}
	}
}

## The status for an error `respond!` returns, by its tag: `NotFound` is
## 404, `BadRequest` 400, the database's writer busy 503, anything else
## 500.
error_status : Str -> U16
error_status = |inspected|
	if is_tag(inspected, "NotFound") {
		404
	} else if is_tag(inspected, "BadRequest") {
		400
	} else if Str.starts_with(inspected, "DbErr(WriterBusy(") {
		503
	} else {
		500
	}

is_tag : Str, Str -> Bool
is_tag = |inspected, tag| inspected == tag or Str.starts_with(inspected, "${tag}(")

expect error_status("NotFound") == 404
expect error_status("NotFound(\"post\")") == 404
expect error_status("NotFoundish") == 500
expect error_status("BadRequest(\"no id\")") == 400
expect error_status("DbErr(WriterBusy(\"64 requests wait\"))") == 503
expect error_status("DbErr(Failed(\"disk I/O error\"))") == 500
