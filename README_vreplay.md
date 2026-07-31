the command to run will now be ./ocamlc -visual-replay Vreplay.mli Vreplay.ml <your-file>


there is a vreplay module inside the compiler in parsing. this is part of the compiler now.
there is a vreplay folder with modules inside in this repo. these are not part of the compiler and should be compiled and linked whenever -visual-replay flag is passed.



dependencis for separate vreplay folder so far include: 
- Core

## Where the dump goes

The instrumented program picks its dump sink at the first event, from the
environment:

- `VREPLAY_SOCK=<path>` -- connect a Unix domain stream socket (a live
  listener, e.g. the debugger interface). If the connect fails it warns on
  stderr and falls through to the file sink.
- `VREPLAY_FILE=<path>` -- write that file (truncated at start).
- neither -- write `./vreplay.dump`.

The dump never goes to stdout, so the program's own printing cannot corrupt
it. If the sink cannot be opened at all (or a write fails), a one-line
warning goes to stderr and further emission is disabled; the program keeps
running.
