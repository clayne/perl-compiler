%int::; #create int package for types sub x(int,int) { @_ } #cvproto my $o = prototype \&x; if ($o eq "int,int") {print "o"}else{print $o}; sub y($) { @_ } #cvproto my $p = prototype \&y; if ($p eq q($)) {print "k"}else{print $p}; require bytes; sub my::length ($) { # possible prototype mismatch vs _ if ( bytes->can(q(length)) ) { *length = *bytes::length; goto &bytes::length; } return CORE::length( $_[0] ); } print my::length($p);
### RESULT:ok1
