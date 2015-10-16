package B::C::Config;

use strict;

use B::C::Flags         ();
use B::C::Config::Debug ();

use Exporter ();
our @ISA = qw(Exporter);

# alias
*debug           = \&B::C::Config::Debug::debug;
*debug_all       = \&B::C::Config::Debug::enable_all;
*verbose         = \&B::C::Config::Debug::verbose;
*display_message = \&B::C::Config::Debug::display_message;

*WARN = \&B::C::Config::Debug::WARN;

sub _autoload_map {
    my $map = {
        USE_ITHREADS     => $B::C::Flags::Config{useithreads},
        USE_MULTIPLICITY => $B::C::Flags::Config{usemultiplicity},

        # Thanks to Mattia Barbon for the C99 tip to init any union members
        C99 => $B::C::Flags::Config{d_c99_variadic_macros},    # http://docs.sun.com/source/819-3688/c99.app.html#pgfId-1003962

        MAD => $B::C::Flags::Config{mad},
    };
    $map->{HAVE_DLFCN_DLOPEN} = $B::C::Flags::Config{i_dlfcn} && $B::C::Flags::Config{d_dlopen};

    # debugging variables
    $map->{'DEBUGGING'}             = ( $B::C::Flags::Config{ccflags} =~ m/-DDEBUGGING/ );
    $map->{'DEBUG_LEAKING_SCALARS'} = $B::C::Flags::Config{ccflags} =~ m/-DDEBUG_LEAKING_SCALARS/;

    return $map;
}

my $_autoload;

BEGIN {
    $_autoload = _autoload_map();
    our @EXPORT_OK = keys %$_autoload;
    push @EXPORT_OK, qw/debug debug_all display_message verbose WARN INFO FATAL/;
    our @EXPORT = @EXPORT_OK;
}

our $AUTOLOAD;

sub AUTOLOAD {
    my $ask_for = $AUTOLOAD;
    $ask_for =~ s/.*:://;

    $ask_for =~ s/sect$//;    # Strip sect off the call so we can just access the key.

    exists $_autoload->{$ask_for} or die("Tried to call undefined subroutine '$ask_for'");
    return $_autoload->{$ask_for};
}

1;
