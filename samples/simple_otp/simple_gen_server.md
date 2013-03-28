# simple_gen_server

A basic `gen_server` showing a *synchronous call* taking too long
can be a bottleneck when *asynchronous calls* try be get processed.

## simple_gen_server:start(Pause, Nb_casts)

    simple_gen_server:start(2, 10).

A single `call` will be done, taking `Pause` seconds
and before it ends `Nb_casts` will be made to the `gen_server`
returning only when the call has returned.

On the tree-graph, it will translate into `Nb_casts` node being created,
only to be destructed `Pause` seconds later.

