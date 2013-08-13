cx_runtime
==========

The Concurix system for dynamically enhancing the Erlang Virtual Machine

NOTE!!  After August 12 2013, the minimum version required is concurix_runtime_r0.7

Dependencies
. rebar
. make

Build
To build the cx_runtime library just run make.
$ make

To use with default settings, use the api 

concurix_runtime:start()

This will turn on default tracing, viewable from the default Localhost project on www.concurix.com

For instructions on how to use the cx_runtime, see
http://www.concurix.com/main/documentation