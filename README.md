# ts

`ts` adds a timestamp to the beginning of each line of input.

This is a partial port of moreutils ts to zig optimized for high throughput. It is between 10 to 20 times faster than the perl version.

## Usage

    usage: ts [-i | -s] [-m] [format]

The optional format parameter controls how the timestamp is formatted, as used
by L<strftime(3)>. The default format is "%b %d %H:%M:%S". In addition to the
regular strftime conversion specifications, "%.S" and "%.s" and "%.T" are like
"%S" and "%s" and "%T", but provide subsecond resolution (ie, "30.00001" and
"1301682593.00001" and "1:15:30.00001").

If the -i or -s switch is passed, ts timestamps incrementally instead. In case
of -i, every timestamp will be the time elapsed since the last timestamp. In
case of -s, the time elapsed since start of the program is used. The default
format changes to "%H:%M:%S", and "%.S" and "%.s" can be used as well.

The -m switch makes the system's monotonic clock be used.

The standard TZ environment variable controls what time zone dates are assumed
to be in, if a timezone is not specified as part of the date.

## Benchmark

Call `make benchmark` to compare this version of `ts` with the perl version
included on moreutils.

On a 2019 MacBook Pro, `ts` is 10x faster than the perl version.

    Benchmarking ts.zig
    3.00M 0:00:03 [ 841k/s]
    Benchmarking ts.pl
    3.00M 0:00:33 [89.1k/s]

## Development

Internally, `ts` uses C date and time functions from the C standard library
[]`time.h`](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/time.h.html).

We use zig 0.11.0. Running `./install-zig.sh` will download the zig 0.11.0
release and install it to ./zig/

## Building

    make build

## Testing

    make test
