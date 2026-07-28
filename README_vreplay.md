the command to run will now be ./ocamlc -visual-replay Vreplay.mli Vreplay.ml <your-file>


there is a vreplay module inside the compiler in parsing. this is part of the compiler now.
there is a vreplay folder with modules inside in this repo. these are not part of the compiler and should be compiled and linked whenever -visual-replay flag is passed.



dependencis for separate vreplay folder so far include: 
- Core