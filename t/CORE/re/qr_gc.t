#!./perl -w

BEGIN {
    require q(t/CORE/test.pl);
    undef &Regexp::DESTROY;
}

plan tests => 2;

my $destroyed;
{
    sub Regexp::DESTROY { $destroyed++ }
}

{
    my $rx = qr//;
}

is( $destroyed, 1, "destroyed regexp" );

undef $destroyed;

{
    my $var = bless {}, "Foo";
    my $rx = qr/(?{ $var })/;
}

is( $destroyed, 1, "destroyed regexp with closure capture" );
