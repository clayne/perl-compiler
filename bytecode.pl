BEGIN {
  push @INC, '.', 'lib';
  require 'regen_lib.pl';
}
use strict;
use Config;
my %alias_to = (
    U32 => [qw(line_t)],
    PADOFFSET => [qw(STRLEN SSize_t)],
    U16 => [qw(OPCODE short)],
    U8  => [qw(char)],
);

my (%alias_from, $from, $tos);
while (($from, $tos) = each %alias_to) {
    map { $alias_from{$_} = $from } @$tos;
}
my (@optype, @specialsv_name);
require B;
if ($] < 5.009) {
  require B::Asmdata;
  @optype = @{*B::Asmdata::optype{ARRAY}};
  @specialsv_name = @{*B::Asmdata::specialsv_name{ARRAY}};
  # import B::Asmdata qw(@optype @specialsv_name);
} else {
  @optype = @{*B::optype{ARRAY}};
  @specialsv_name = @{*B::specialsv_name{ARRAY}};
  # import B qw(@optype @specialsv_name);
}

my $c_header = <<'EOT';
/* -*- buffer-read-only: t -*-
 *
 *      Copyright (c) 1996-1999 Malcolm Beattie
 *      Copyright (c) 2008 Reini Urban
 *
 *      You may distribute under the terms of either the GNU General Public
 *      License or the Artistic License, as specified in the README file.
 *
 */
/*
 * This file is autogenerated from bytecode.pl. Changes made here will be lost.
 */
EOT

my $perl_header;
($perl_header = $c_header) =~ s{[/ ]?\*/?}{#}g;
my @targets = ("lib/B/Asmdata.pm", "ByteLoader/byterun.c", "ByteLoader/byterun.h");

safer_unlink @targets;

#
# Start with boilerplate for Asmdata.pm
#
open(ASMDATA_PM, "> $targets[0]") or die "$targets[0]: $!";
binmode ASMDATA_PM;
print ASMDATA_PM $perl_header, <<'EOT';
package B::Asmdata;

our $VERSION = '1.02_01';

use Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(%insn_data @insn_name @optype @specialsv_name);
EOT

if ($] > 5.009) {
  print ASMDATA_PM 'our(%insn_data, @insn_name);

use B qw(@optype @specialsv_name);
';
} else {
    print ASMDATA_PM 'our(%insn_data, @insn_name, @optype, @specialsv_name);

@optype = qw(OP UNOP BINOP LOGOP LISTOP PMOP SVOP PADOP PVOP LOOP COP);
@specialsv_name = qw(Nullsv &PL_sv_undef &PL_sv_yes &PL_sv_no pWARN_ALL pWARN_NONE);
';
}

print ASMDATA_PM <<"EOT";

# XXX insn_data is initialised this way because with a large
# %insn_data = (foo => [...], bar => [...], ...) initialiser
# I get a hard-to-track-down stack underflow and segfault.
EOT

#
# Boilerplate for byterun.c
#
open(BYTERUN_C, "> $targets[1]") or die "$targets[1]: $!";
binmode BYTERUN_C;
print BYTERUN_C $c_header, <<'EOT';

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#define NO_XSLOCKS
#include "XSUB.h"

#ifndef PL_tokenbuf /* Change 31252: move PL_tokenbuf into the PL_parser struct */
#define PL_tokenbuf		(PL_parser->tokenbuf)
#endif

#include "byterun.h"
#include "bytecode.h"

static const int optype_size[] = {
EOT
my $i = 0;
for ($i = 0; $i < @optype - 1; $i++) {
    printf BYTERUN_C "    sizeof(%s),\n", $optype[$i], $i;
}
printf BYTERUN_C "    sizeof(%s)\n", $optype[$i], $i;
print BYTERUN_C <<'EOT';
};

void *
bset_obj_store(pTHX_ struct byteloader_state *bstate, void *obj, I32 ix)
{
    if (ix > bstate->bs_obj_list_fill) {
	Renew(bstate->bs_obj_list, ix + 32, void*);
	bstate->bs_obj_list_fill = ix + 31;
    }
    bstate->bs_obj_list[ix] = obj;
    return obj;
}

int
byterun(pTHX_ struct byteloader_state *bstate)
{
    register int insn;
    U32 isjit = 0;
    U32 ix;
EOT
printf BYTERUN_C "    SV *specialsv_list[%d];\n", scalar @specialsv_name;
print BYTERUN_C <<'EOT';

    BYTECODE_HEADER_CHECK;	/* croak if incorrect platform, set isjit on PLJC magic header */
    if (isjit) {
	Perl_croak(aTHX_ "No PLJC-magic JIT support yet\n");
        return 0; /*jitrun(aTHX_ &bstate);*/
    } else {
        Newx(bstate->bs_obj_list, 32, void*); /* set op objlist */
        bstate->bs_obj_list_fill = 31;
        bstate->bs_obj_list[0] = NULL; /* first is always Null */
        bstate->bs_ix = 1;
	CopLINE(PL_curcop) = bstate->bs_fdata->next_out;
	DEBUG_l( Perl_deb(aTHX_ "(bstate.bs_fdata.idx %d)\n", bstate->bs_fdata->idx));
	DEBUG_l( Perl_deb(aTHX_ "(bstate.bs_fdata.next_out %d)\n", bstate->bs_fdata->next_out));
	DEBUG_l( Perl_deb(aTHX_ "(bstate.bs_fdata.datasv %p:\"%s\")\n", bstate->bs_fdata->datasv,
				 SvPV_nolen(bstate->bs_fdata->datasv)));

EOT

for my $i ( 0 .. $#specialsv_name ) {
    print BYTERUN_C "        specialsv_list[$i] = $specialsv_name[$i];\n";
}

print BYTERUN_C <<'EOT';

        while ((insn = BGET_FGETC()) != EOF) {
	  CopLINE(PL_curcop) = bstate->bs_fdata->next_out;
          if (PL_op && DEBUG_t_TEST_) debop(PL_op);
	  switch (insn) {
EOT


my (@insn_name, $insn_num, $ver, $insn, $lvalue, $argtype, $flags, $fundtype);

while (<DATA>) {
    if (/^\s*#/) {
	print BYTERUN_C if /^\s*#\s*(?:if|endif|el)/;
	next;
    }
    chop;
    next unless length;
    if (/^%number\s+(.*)/) {
	$insn_num = $1;
	next;
    } elsif (/%enum\s+(.*?)\s+(.*)/) {
	create_enum($1, $2);	# must come before instructions
	next;
    }
    ($ver, $insn, $lvalue, $argtype, $flags) = split;
    my $rvalcast = '';
    if ($argtype =~ m:(.+)/(.+):) {
	($rvalcast, $argtype) = ("($1)", $2);
    }
    if ($ver) {
      if ($ver =~ /^\!?i$/) {
	my $thisthreads = $Config{useithreads} eq 'define';
	next if ($ver eq 'i' and  !$thisthreads) or ($ver eq '!i' and $thisthreads);
      } else { # perl version 5.010 >= 10, 5.009 > 9
	# Have to round the float: 5.010 - 5 = 0.00999999999999979
	my $pver = sprintf("%d", (sprintf("%f",$] - 5) * 1000));
	if ($ver =~ /^\>\d+$/) {
	  next if $pver < substr($ver,1); # ver >10: skip if pvar lowereq 10
        } elsif ($ver =~ /^\<\d*$/) {
	  next if $pver >= substr($ver,1); # ver <10: skip if pvar higher than 10;
        } elsif ($ver =~ /^\d*$/) {
	  next if $pver < $ver; # ver 10: skip if pvar lower than 10;
	}
      }
    }
    $insn_name[$insn_num] = $insn;
    $fundtype = $alias_from{$argtype} || $argtype;

    #
    # Add the case statement and code for the bytecode interpreter in byterun.c
    #
    printf BYTERUN_C "\t  case INSN_%s:\t\t/* %d */\n\t    {\n",
	uc($insn), $insn_num;
    my $optarg = $argtype eq "none" ? "" : ", arg";
    if ($optarg) {
	printf BYTERUN_C "\t\t$argtype arg;\n\t\tBGET_%s(arg);\n", $fundtype;
	print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"(insn %3d) $insn $argtype:%d\\n\", insn, arg));\n";
    } else {
	print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"(insn %3d) $insn\\n\", insn));\n";
    }
    if ($flags =~ /x/) {
	print BYTERUN_C "\t\tBSET_$insn($lvalue$optarg);\n";
	print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   BSET_$insn($lvalue$optarg)\\n\"));\n";
    } elsif ($flags =~ /s/) {
	# Store instructions store to bytecode_obj_list[arg]. "lvalue" field is rvalue.
	print BYTERUN_C "\t\tBSET_OBJ_STORE($lvalue$optarg);\n";
	print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   BSET_OBJ_STORE($lvalue$optarg)\\n\"));\n";
    }
    elsif ($optarg && $lvalue ne "none") {
	print BYTERUN_C "\t\t$lvalue = ${rvalcast}arg;\n";
	print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   $lvalue = ${rvalcast}arg;\\n\"));\n";
    }
    print BYTERUN_C "\t\tbreak;\n\t    }\n";

    #
    # Add the initialiser line for %insn_data in Asmdata.pm
    #
    print ASMDATA_PM <<"EOT";
\$insn_data{$insn} = [$insn_num, \\&PUT_$fundtype, "GET_$fundtype"];
EOT

    # Find the next unused instruction number
    do { $insn_num++ } while $insn_name[$insn_num];
}

#
# Finish off byterun.c
#
print BYTERUN_C <<'EOT';
	    default:
	      Perl_croak(aTHX_ "Illegal bytecode instruction %d\n", insn);
	      /* NOTREACHED */
	  }
        }
    }
    return 0;
}

/* ex: set ro: */
EOT

#
# Write the instruction and optype enum constants into byterun.h
#
open(BYTERUN_H, "> $targets[2]") or die "$targets[2]: $!";
binmode BYTERUN_H;
print BYTERUN_H $c_header, <<'EOT';
#if PERL_VERSION < 10
#define PL_RSFP PL_rsfp
#else
#define PL_RSFP PL_parser->rsfp
#endif

struct byteloader_fdata {
    SV	*datasv;
    int next_out;
    int	idx;
};

#if PERL_VERSION > 8

struct byteloader_xpv {
    char *xpv_pv;
    int xpv_cur;
    int	xpv_len;
};

#endif

struct byteloader_state {
    struct byteloader_fdata	*bs_fdata;
    SV				*bs_sv;
    void			**bs_obj_list;
    int				bs_obj_list_fill;
    int				bs_ix;
#if PERL_VERSION > 8
    struct byteloader_xpv	bs_pv;
#else
    XPV				bs_pv;
#endif
    int				bs_iv_overflows;
};

int bl_getc(struct byteloader_fdata *);
int bl_read(struct byteloader_fdata *, char *, size_t, size_t);
extern int byterun(pTHX_ register struct byteloader_state *);

enum {
EOT

my $add_enum_value = 0;
my $max_insn;
for $i ( 0 .. $#insn_name ) {
    $insn = uc($insn_name[$i]);
    if (defined($insn)) {
	$max_insn = $i;
	if ($add_enum_value) {
	    print BYTERUN_H "    INSN_$insn = $i,\t\t\t/* $i */\n";
	    $add_enum_value = 0;
	} else {
	    print BYTERUN_H "    INSN_$insn,\t\t\t/* $i */\n";
	}
    } else {
	$add_enum_value = 1;
    }
}

print BYTERUN_H "    MAX_INSN = $max_insn\n};\n";

print BYTERUN_H "\nenum {\n";
for ($i = 0; $i < @optype - 1; $i++) {
    printf BYTERUN_H "    OPt_%s,\t\t/* %d */\n", $optype[$i], $i;
}
printf BYTERUN_H "    OPt_%s\t\t/* %d */\n};\n\n", $optype[$i], $i;

print BYTERUN_H "/* ex: set ro: */\n";

#
# Finish off insn_data and create array initialisers in Asmdata.pm
#
print ASMDATA_PM <<'EOT';

my ($insn_name, $insn_data);
while (($insn_name, $insn_data) = each %insn_data) {
    $insn_name[$insn_data->[0]] = $insn_name;
}
# Fill in any gaps
@insn_name = map($_ || "unused", @insn_name);

1;

__END__

=head1 NAME

B::Asmdata - Autogenerated data about Perl ops, used to generate bytecode

=head1 SYNOPSIS

	use B::Asmdata qw(%insn_data @insn_name @optype @specialsv_name);

=head1 DESCRIPTION

Provides information about Perl ops in order to generate bytecode via
a bunch of exported variables.  Its mostly used by B::Assembler and
B::Disassembler.

=over 4

=item %insn_data

  my($bytecode_num, $put_sub, $get_meth) = @$insn_data{$op_name};

For a given $op_name (for example, 'cop_label', 'sv_flags', etc...)
you get an array ref containing the bytecode number of the op, a
reference to the subroutine used to 'PUT' the op argument to the bytecode stream,
and the name of the method used to 'GET' op argument from the bytecode stream.

Most ops require one arg, in fact all ops without the PUT/GET_none methods,
and the GET and PUT methods are used to en-/decode the arg to binary bytecode.
The names are constructed from the GET/PUT prefix and the argument type,
such as U8, U16, U32, svindex, opindex, pvindex, ...

The PUT method is used in the L<B::Bytecode> compiler within L<B::Assembler>,
the GET method just for the L<B::Disassembler>.
The GET method is not used by the binary L<ByteLoader> module.

A full C<insn> table with version, opcode, name, lvalue, argtype and flags
is located as DATA in F<bytecode.pl>.

=item @insn_name

  my $op_name = $insn_name[$bytecode_num];

A simple mapping of the bytecode number to the name of the op.
Suitable for using with %insn_data like so:

  my $op_info = $insn_data{$insn_name[$bytecode_num]};

=item @optype

  my $op_type = $optype[$op_type_num];

A simple mapping of the op type number to its type (like 'COP' or 'BINOP').

Since Perl version 5.10 defined in L<B>.

=item @specialsv_name

  my $sv_name = $specialsv_name[$sv_index];

Certain SV types are considered 'special'.  They're represented by
B::SPECIAL and are referred to by a number from the specialsv_list.
This array maps that number back to the name of the SV (like 'Nullsv'
or '&PL_sv_undef').

Since Perl version 5.10 defined in L<B>.

=back

=head1 AUTHOR

Malcolm Beattie, C<mbeattie@sable.ox.ac.uk>
Reini Urban added the version logic and 5.10 support.

=cut

# ex: set ro:
EOT

close ASMDATA_PM or die "Error closing $targets[0]: $!";
close BYTERUN_C or die "Error closing $targets[1]: $!";
close BYTERUN_H or die "Error closing $targets[2]: $!";
chmod 0444, @targets;

# TODO 5.10:
#   stpv
#   pv_free: free the bs_pv and the SvPVX?

__END__
# First set instruction ord("#") to read comment to end-of-line (sneaky)
%number 35
0 comment	arg			comment_t
# Then make ord("\n") into a no-op
%number 10
0 nop		none			none

# Now for the rest of the ordinary ones, beginning with \0 which is
# ret so that \0-terminated strings can be read properly as bytecode.
%number 0
#
# The argtype is either a single type or "rightvaluecast/argtype".
# The version is either "i" or "!i" for ithreads or not, or num, >num or <num.
# "0" is for all, "<10" requires PERL_VERSION<10, "10" or ">10" requires
# PERL_VERSION>10
#
#version opcode	lvalue					argtype		flags
#
0 ret		none					none		x
0 ldsv		bstate->bs_sv				svindex
0 ldop		PL_op					opindex
0 stsv		bstate->bs_sv				U32		s
0 stop		PL_op					U32		s
0 stpv		bstate->bs_pv.xpv_pv			U32		x
0 ldspecsv	bstate->bs_sv				U8		x
0 ldspecsvx	bstate->bs_sv				U8		x
0 newsv		bstate->bs_sv				U8		x
0 newsvx	bstate->bs_sv				U32		x
0 newop		PL_op					U8		x
0 newopx	PL_op					U16		x
0 newopn	PL_op					U8		x
0 newpv		none					U32/PV
0 pv_cur	bstate->bs_pv.xpv_cur			STRLEN
0 pv_free	bstate->bs_pv				none		x
0 sv_upgrade	bstate->bs_sv				U8		x
0 sv_refcnt	SvREFCNT(bstate->bs_sv)			U32
0 sv_refcnt_add	SvREFCNT(bstate->bs_sv)			I32		x
0 sv_flags	SvFLAGS(bstate->bs_sv)			U32
0 xrv		bstate->bs_sv				svindex		x
0 xpv		bstate->bs_sv				none		x
0 xpv_cur	bstate->bs_sv	 			STRLEN		x
0 xpv_len	bstate->bs_sv				STRLEN		x
0 xiv		bstate->bs_sv				IV		x
0 xnv		bstate->bs_sv				NV		x
0 xlv_targoff	LvTARGOFF(bstate->bs_sv)		STRLEN
0 xlv_targlen	LvTARGLEN(bstate->bs_sv)		STRLEN
0 xlv_targ	LvTARG(bstate->bs_sv)			svindex
0 xlv_type	LvTYPE(bstate->bs_sv)			char
0 xbm_useful	BmUSEFUL(bstate->bs_sv)			I32
0 xbm_previous	BmPREVIOUS(bstate->bs_sv)		U16
0 xbm_rare	BmRARE(bstate->bs_sv)			U8
0 xfm_lines	FmLINES(bstate->bs_sv)			IV
0 xio_lines	IoLINES(bstate->bs_sv)			IV
0 xio_page	IoPAGE(bstate->bs_sv)			IV
0 xio_page_len	IoPAGE_LEN(bstate->bs_sv)		IV
0 xio_lines_left IoLINES_LEFT(bstate->bs_sv)	       	IV
0 xio_top_name	IoTOP_NAME(bstate->bs_sv)		pvindex
0 xio_top_gv	*(SV**)&IoTOP_GV(bstate->bs_sv)		svindex
0 xio_fmt_name	IoFMT_NAME(bstate->bs_sv)		pvindex
0 xio_fmt_gv	*(SV**)&IoFMT_GV(bstate->bs_sv)		svindex
0 xio_bottom_name IoBOTTOM_NAME(bstate->bs_sv)		pvindex
0 xio_bottom_gv	*(SV**)&IoBOTTOM_GV(bstate->bs_sv)	svindex
<10 xio_subprocess IoSUBPROCESS(bstate->bs_sv)		short
0 xio_type	IoTYPE(bstate->bs_sv)			char
0 xio_flags	IoFLAGS(bstate->bs_sv)			char
0 xcv_xsubany	*(SV**)&CvXSUBANY(bstate->bs_sv).any_ptr	svindex
0 xcv_stash	*(SV**)&CvSTASH(bstate->bs_sv)		svindex
0 xcv_start	CvSTART(bstate->bs_sv)			opindex
0 xcv_root	CvROOT(bstate->bs_sv)			opindex
0 xcv_gv	*(SV**)&CvGV(bstate->bs_sv)		svindex
0 xcv_file	CvFILE(bstate->bs_sv)			pvindex
0 xcv_depth	CvDEPTH(bstate->bs_sv)			long
0 xcv_padlist	*(SV**)&CvPADLIST(bstate->bs_sv)	svindex
0 xcv_outside	*(SV**)&CvOUTSIDE(bstate->bs_sv)	svindex
0 xcv_outside_seq CvOUTSIDE_SEQ(bstate->bs_sv)		U32
0 xcv_flags	CvFLAGS(bstate->bs_sv)			U16
0 av_extend	bstate->bs_sv				SSize_t		x
0 av_pushx	bstate->bs_sv				svindex		x
0 av_push	bstate->bs_sv				svindex		x
0 xav_fill	AvFILLp(bstate->bs_sv)			SSize_t
0 xav_max	AvMAX(bstate->bs_sv)			SSize_t
<10 xav_flags	AvFLAGS(bstate->bs_sv)			U8
10 xav_flags	((XPVAV*)(SvANY(bstate->bs_sv)))->xiv_u.xivu_i32	I32
<10 xhv_riter	HvRITER(bstate->bs_sv)			I32
0 xhv_name	bstate->bs_sv				pvindex		x
<10 xhv_pmroot	*(OP**)&HvPMROOT(bstate->bs_sv)		opindex
0 hv_store	bstate->bs_sv				svindex		x
0 sv_magic	bstate->bs_sv				char		x
0 mg_obj	SvMAGIC(bstate->bs_sv)->mg_obj		svindex
0 mg_private	SvMAGIC(bstate->bs_sv)->mg_private	U16
0 mg_flags	SvMAGIC(bstate->bs_sv)->mg_flags	U8
0 mg_name	SvMAGIC(bstate->bs_sv)			pvcontents	x
0 mg_namex	SvMAGIC(bstate->bs_sv)			svindex		x
0 xmg_stash	bstate->bs_sv				svindex		x
0 gv_fetchpv	bstate->bs_sv				strconst	x
0 gv_fetchpvx	bstate->bs_sv				strconst	x
0 gv_stashpv	bstate->bs_sv				strconst	x
0 gv_stashpvx	bstate->bs_sv				strconst	x
0 gp_sv		GvSV(bstate->bs_sv)			svindex
0 gp_refcnt	GvREFCNT(bstate->bs_sv)			U32
0 gp_refcnt_add	GvREFCNT(bstate->bs_sv)			I32		x
0 gp_av		*(SV**)&GvAV(bstate->bs_sv)		svindex
0 gp_hv		*(SV**)&GvHV(bstate->bs_sv)		svindex
0 gp_cv		*(SV**)&GvCV(bstate->bs_sv)		svindex
<9 gp_file	GvFILE(bstate->bs_sv)			pvindex
9 gp_file	GvFILE_HEK(bstate->bs_sv)		hekindex
0 gp_io		*(SV**)&GvIOp(bstate->bs_sv)		svindex
0 gp_form	*(SV**)&GvFORM(bstate->bs_sv)		svindex
0 gp_cvgen	GvCVGEN(bstate->bs_sv)			U32
0 gp_line	GvLINE(bstate->bs_sv)			line_t
0 gp_share	bstate->bs_sv				svindex		x
0 xgv_flags	GvFLAGS(bstate->bs_sv)			U8
0 op_next	PL_op->op_next				opindex
0 op_sibling	PL_op->op_sibling			opindex
0 op_ppaddr	PL_op->op_ppaddr			strconst	x
0 op_targ	PL_op->op_targ				PADOFFSET
0 op_type	PL_op					OPCODE		x
<9 op_seq	PL_op->op_seq				U16
9 op_opt	PL_op->op_opt				U8
9 op_latefree	PL_op->op_latefree			U8
9 op_latefreed	PL_op->op_latefreed			U8
9 op_attached	PL_op->op_attached			U8
0 op_flags	PL_op->op_flags				U8
0 op_private	PL_op->op_private			U8
0 op_first	cUNOP->op_first				opindex
0 op_last	cBINOP->op_last				opindex
0 op_other	cLOGOP->op_other			opindex
<10 op_pmreplroot  cPMOP->op_pmreplroot			opindex
<10 op_pmreplstart cPMOP->op_pmreplstart		opindex
<10 op_pmnext	*(OP**)&cPMOP->op_pmnext		opindex
10 op_pmreplroot   (cPMOP->op_pmreplrootu).op_pmreplroot	opindex
10 op_pmreplstart  (cPMOP->op_pmstashstartu).op_pmreplstart	opindex
#ifdef USE_ITHREADS
i op_pmstashpv		cPMOP				pvindex		x
<10 op_pmreplrootpo	cPMOP->op_pmreplroot		OP*/PADOFFSET
10 op_pmreplrootpo	(cPMOP->op_pmreplrootu).op_pmreplroot	OP*/PADOFFSET
#else
0 op_pmstash		*(SV**)&cPMOP->op_pmstash		svindex
<10 op_pmreplrootgv	*(SV**)&cPMOP->op_pmreplroot		svindex
10 op_pmreplrootgv	*(SV**)&((cPMOP->op_pmreplrootu).op_pmreplroot)	svindex
#endif
<10 pregcomp	PL_op					pvcontents	x
10 pregcomp	PL_op					none	x
0 op_pmflags	cPMOP->op_pmflags			U16
#if PERL_VERSION < 11
10 op_reflags	PM_GETRE(cPMOP)->extflags		U32
#else
11 op_reflags	((ORANGE*)SvANY(PM_GETRE(cPMOP)))->extflags	U32
#endif
<10 op_pmpermflags cPMOP->op_pmpermflags		U16
<10 op_pmdynflags  cPMOP->op_pmdynflags			U8
0 op_sv		cSVOP->op_sv				svindex
0 op_padix	cPADOP->op_padix			PADOFFSET
0 op_pv		cPVOP->op_pv				pvcontents
0 op_pv_tr	cPVOP->op_pv				op_tr_array
0 op_redoop	cLOOP->op_redoop			opindex
0 op_nextop	cLOOP->op_nextop			opindex
0 op_lastop	cLOOP->op_lastop			opindex
0 cop_label	cCOP->cop_label				pvindex
i cop_stashpv	cCOP					pvindex		x
i cop_file	cCOP					pvindex		x
# /* those two are ignored, but keep .plc compat for 5.8 only? */
#ifndef USE_ITHREADS
0 cop_stash	cCOP					svindex		x
0 cop_filegv	cCOP					svindex		x
#endif
0 cop_seq	cCOP->cop_seq				U32
<10 cop_arybase	cCOP->cop_arybase			I32
0 cop_line	cCOP->cop_line				line_t
<10 cop_io	cCOP->cop_io				svindex
0 cop_warnings	cCOP					svindex		x
0 main_start	PL_main_start				opindex
0 main_root	PL_main_root				opindex
0 main_cv	*(SV**)&PL_main_cv			svindex
0 curpad	PL_curpad				svindex		x
0 push_begin	PL_beginav				svindex		x
0 push_init	PL_initav				svindex		x
0 push_end	PL_endav				svindex		x
0 curstash	*(SV**)&PL_curstash			svindex
0 defstash	*(SV**)&PL_defstash			svindex
0 data		none					U8		x
0 incav		*(SV**)&GvAV(PL_incgv)			svindex
0 load_glob	none					svindex		x
#ifdef USE_ITHREADS
i regex_padav	*(SV**)&PL_regex_padav			svindex
#endif
0 dowarn	PL_dowarn				U8
0 comppad_name	*(SV**)&PL_comppad_name			svindex
0 xgv_stash	*(SV**)&GvSTASH(bstate->bs_sv)		svindex
0 signal	bstate->bs_sv				strconst	x
# to be removed
0 formfeed	PL_formfeed				svindex
