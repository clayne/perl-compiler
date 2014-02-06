#! /usr/bin/env perl
# http://code.google.com/p/perl-compiler/issues/detail?id=197
# missing package DESTROY
use strict;
BEGIN {
  unshift @INC, 't';
  require "test.pl";
}
use Test::More tests => 5;

my $exp = "ok - dynamic destruction
ok - lexical destruction
ok - package destruction";

my $todo = $] >= 5.018 ? "" : "TODO ";
my $script197 = <<'EOF';
package FINALE;
{
    $ref3 = bless ["ok - package destruction"];
    my $ref2 = bless ["ok - lexical destruction\n"];
    local $ref1 = bless ["ok - dynamic destruction\n"];
    1;
}
DESTROY {
    print $_[0][0];
}
EOF

ctest(1,$exp,'C,-O2','ccode197i',$script197,$todo.'missing package DESTROY #197');
ctest(2,$exp,'C,-O3','ccode197i',$script197,'TODO missing -O3 DESTROY #208');

$exp = $] > 5.013005 ? "RUN MyKooh DESTRUCT OurKooh" : " MyKooh  OurKooh";

my $script208 = <<'EOF';
sub MyKooh::DESTROY { print "${^GLOBAL_PHASE} MyKooh " }  my $k=bless {}, MyKooh;
sub OurKooh::DESTROY { print "${^GLOBAL_PHASE} OurKooh" }our $k=bless {}, OurKooh;
EOF

ctest(3,$exp,'C,-O2','ccode197i',$script208,$todo.'missing package DESTROY #197');
ctest(4,$exp,'C,-O3','ccode197i',$script208,'TODO missing our -O3 DESTROY #208');

# if the bless happens inside BEGIN: wontfix
ctestok(5,'C,-O3','ccode197i',<<'EOF','TODO: destroy a lexvar #254');
my $flag = 0;
sub X::DESTROY { $flag = 1 }
{
  my $x;              # x only exists in that scope
  BEGIN { $x = 42 }   # initialize this lexvar during compilation
  $x = bless {}, "X"; # run-time bless to call DESTROY
  # undef($x);        # value should be freed when exiting scope
}
print "ok\n" if $flag;
EOF

