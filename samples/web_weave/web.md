# web

A set of processes is created, which in turn creates a set of processes
and so on, a finite number of times.
A message is then sent to the younger ones, they repeat it to their direct
parent, wait some time and then die.

# web:weave/2

What you will be able to see in the force-directed graph
is the branches and leaves of a *tree*. Strokes bonding together *processes*.

When it dies, its outter leaves will die first and thus, moving towards
the center of the tree.

To see the rise and fall of a 3-branched 9-levels tree with one second lapse
between each death-step:

    web:weave(6, 3, 1000).

The number of processes created will be 3^6 = 729.
