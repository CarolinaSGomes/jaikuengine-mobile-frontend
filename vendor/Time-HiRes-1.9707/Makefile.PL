#!/usr/bin/perl
#
# In general we trust %Config, but for nanosleep() this trust
# may be misplaced (it may be linkable but not really functional).
# Use $ENV{FORCE_NANOSLEEP_SCAN} to force rescanning whether there
# really is hope.

require 5.002;

use Config;
use ExtUtils::MakeMaker;
use strict;

my $VERBOSE = $ENV{VERBOSE};
my $DEFINE;
my $LIBS = [];
my $XSOPT = '';
my $SYSCALL_H;

use vars qw($self); # Used in 'sourcing' the hints.

my $ld_exeext = ($^O eq 'cygwin' ||
                 $^O eq 'os2' && $Config{ldflags} =~ /-Zexe\b/) ? '.exe' : '';

unless($ENV{PERL_CORE}) {
    $ENV{PERL_CORE} = 1 if grep { $_ eq 'PERL_CORE=1' } @ARGV;
}

# Perls 5.002 and 5.003 did not have File::Spec, fake what we need.

sub my_dirsep {
    $^O eq 'VMS' ? '.' :
	$^O =~ /mswin32|netware|djgpp/i ? '\\' :
	    $^O eq 'MacOS' ? ':'
		: '/';
}

sub my_catdir {
    shift;
    my $catdir = join(my_dirsep, @_);
    $^O eq 'VMS' ? "[$catdir]" : $catdir;
}

sub my_catfile {
    shift;
    return join(my_dirsep, @_) unless $^O eq 'VMS';
    my $file = pop;
    return my_catdir (undef, @_) . $file;
}

sub my_updir {
    shift;
    $^O eq 'VMS' ? "-" : "..";
}

BEGIN {
    eval { require File::Spec };
    if ($@) {
	*File::Spec::catdir  = \&my_catdir;
	*File::Spec::updir   = \&my_updir;
	*File::Spec::catfile = \&my_catfile;
    }
}

# Avoid 'used only once' warnings.
my $nop1 = *File::Spec::catdir;
my $nop2 = *File::Spec::updir;
my $nop3 = *File::Spec::catfile;

# if you have 5.004_03 (and some slightly older versions?), xsubpp
# tries to generate line numbers in the C code generated from the .xs.
# unfortunately, it is a little buggy around #ifdef'd code.
# my choice is leave it in and have people with old perls complain
# about the "Usage" bug, or leave it out and be unable to compile myself
# without changing it, and then I'd always forget to change it before a
# release. Sorry, Edward :)

sub try_compile_and_link {
    my ($c, %args) = @_;

    my ($ok) = 0;
    my ($tmp) = "tmp$$";
    local(*TMPC);

    my $obj_ext = $Config{obj_ext} || ".o";
    unlink("$tmp.c", "$tmp$obj_ext");

    if (open(TMPC, ">$tmp.c")) {
	print TMPC $c;
	close(TMPC);

	my $cccmd = $args{cccmd};

	my $errornull;

	my $COREincdir;

	if ($ENV{PERL_CORE}) {
	    my $updir = File::Spec->updir;
	    $COREincdir = File::Spec->catdir(($updir) x 3);
	} else {
	    $COREincdir = File::Spec->catdir($Config{'archlibexp'}, 'CORE');
	}

	if ($ENV{PERL_CORE}) {
	    unless (-f File::Spec->catfile($COREincdir, "EXTERN.h")) {
		die <<__EOD__;
Your environment variable PERL_CORE is '$ENV{PERL_CORE}' but there
is no EXTERN.h in $COREincdir.
Cannot continue, aborting.
__EOD__
            }
        }

	my $ccflags = $Config{'ccflags'} . ' ' . "-I$COREincdir";

	if ($^O eq 'VMS') {
	    if ($ENV{PERL_CORE}) {
		# Fragile if the extensions change hierarchy within
		# the Perl core but this should do for now.
                $cccmd = "$Config{'cc'} /include=([---]) $tmp.c";
	    } else {
		my $perl_core = $Config{'installarchlib'};
		$perl_core =~ s/\]$/.CORE]/;
                $cccmd = "$Config{'cc'} /include=(perl_root:[000000],$perl_core) $tmp.c";
	    }
        }

        if ($args{silent} || !$VERBOSE) {
	    $errornull = "2>/dev/null" unless defined $errornull;
	} else {
	    $errornull = '';
	}

        $cccmd = "$Config{'cc'} -o $tmp $ccflags $tmp.c @$LIBS $errornull"
	    unless defined $cccmd;

       if ($^O eq 'VMS') {
	    open( CMDFILE, ">$tmp.com" );
	    print CMDFILE "\$ SET MESSAGE/NOFACILITY/NOSEVERITY/NOIDENT/NOTEXT\n";
	    print CMDFILE "\$ $cccmd\n";
	    print CMDFILE "\$ IF \$SEVERITY .NE. 1 THEN EXIT 44\n"; # escalate
	    close CMDFILE;
	    system("\@ $tmp.com");
	    $ok = $?==0;
	    for ("$tmp.c", "$tmp$obj_ext", "$tmp.com", "$tmp$Config{exe_ext}") {
		1 while unlink $_;
	    }
        }
        else
        {
	    my $tmp_exe = "$tmp$ld_exeext";
	    printf "cccmd = $cccmd\n" if $VERBOSE;
	    my $res = system($cccmd);
	    $ok = defined($res) && $res == 0 && -s $tmp_exe && -x _;

	    if ( $ok && exists $args{run} && $args{run}) {
		my $tmp_exe =
		    File::Spec->catfile(File::Spec->curdir, $tmp_exe);
		printf "Running $tmp_exe..." if $VERBOSE;
		if (system($tmp_exe) == 0) {
		    $ok = 1;
		} else {
		    $ok = 0;
		    my $errno = $? >> 8;
		    local $! = $errno;
		    printf <<EOF;

*** The test run of '$tmp_exe' failed: status $?
*** (the status means: errno = $errno or '$!')
*** DO NOT PANIC: this just means that *some* functionality will be missing.
EOF
		}
	    }
	    unlink("$tmp.c", $tmp_exe);
        }
    }

    return $ok;
}

my $TIME_HEADERS = <<EOH;
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef I_SYS_TYPES
#   include <sys/types.h>
#endif
#ifdef I_SYS_TIME
#   include <sys/time.h>
#endif
#ifdef I_SYS_SELECT
#   include <sys/select.h>	/* struct timeval might be hidden in here */
#endif
EOH

sub has_gettimeofday {
    # confusing but true (if condition true ==> -DHAS_GETTIMEOFDAY already)
    return 0 if $Config{d_gettimeod};
    return 1 if try_compile_and_link(<<EOM);
$TIME_HEADERS
static int foo()
{
    struct timeval tv;
    gettimeofday(&tv, 0);
}
int main(int argc, char** argv)
{
    foo();
}
EOM
    return 0;
}

sub has_x {
    my ($x, %args) = @_;

    return 1 if
    try_compile_and_link(<<EOM, %args);
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifdef I_UNISTD
#   include <unistd.h>
#endif

#ifdef I_SYS_TYPES
#   include <sys/types.h>
#endif

#ifdef I_SYS_TIME
#   include <sys/time.h>
#endif

int main(int argc, char** argv)
{
	$x;
}
EOM
    return 0;
}

sub has_nanosleep {
    print "testing... ";
    return 1 if
    try_compile_and_link(<<EOM, run => 1);
#include <time.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

/* int nanosleep(const struct timespec *rqtp, struct timespec *rmtp); */

int main(int argc, char** argv) {
    struct timespec ts1, ts2;
    int ret;
    ts1.tv_sec  = 0;
    ts1.tv_nsec = 750000000;
    ts2.tv_sec  = 0;
    ts2.tv_nsec = 0;
    errno = 0;
    ret = nanosleep(&ts1, &ts2); /* E.g. in AIX nanosleep() fails and sets errno to ENOSYS. */
    ret == 0 ? exit(0) : exit(errno ? errno : -1);
}
EOM
}

sub has_include {
    my ($inc) = @_;
    return 1 if
    try_compile_and_link(<<EOM);
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <$inc>
int main(int argc, char** argv)
{
	return 0;
}
EOM
    return 0;
}

sub has_clock_xxx_syscall {
    my $x = shift;
    return 0 unless defined $SYSCALL_H;
    return 1 if
    try_compile_and_link(<<EOM, run => 1);
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <$SYSCALL_H>
int main(int argc, char** argv)
{
    struct timespec ts;
    /* Many Linuxes get ENOSYS even though the syscall exists. */
    /* All implementations are supposed to support CLOCK_REALTIME. */
    int ret = syscall(SYS_clock_$x, CLOCK_REALTIME, &ts);
    ret == 0 ? exit(0) : exit(errno ? errno : -1);
}
EOM
}

sub has_clock_xxx {
    my $xxx = shift;
    return 1 if
    try_compile_and_link(<<EOM, run => 1);
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
int main(int argc, char** argv)
{
    struct timespec ts;
    int ret = clock_$xxx(CLOCK_REALTIME, &ts); /* Many Linuxes get ENOSYS. */
    /* All implementations are supposed to support CLOCK_REALTIME. */
    ret == 0 ? exit(0) : exit(errno ? errno : -1);
}
EOM
}

sub has_clock {
    return 1 if
    try_compile_and_link(<<EOM, run => 1);
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
int main(int argc, char** argv)
{
    clock_t tictoc;
    clock_t ret = clock();
    ret == (clock_t)-1 ? exit(errno ? errno : -1) : exit(0);
}
EOM
}

sub has_clock_nanosleep {
    return 1 if
    try_compile_and_link(<<EOM, run => 1);
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <time.h>
int main(int argc, char** argv)
{
    int ret;
    struct timespec ts1;
    struct timespec ts2;
    ts1.tv_sec  = 0;
    ts1.tv_nsec = 750000000;;
    ret = clock_nanosleep(CLOCK_MONOTONIC, 0, &ts1, &ts2);
    ret == 0 ? exit(0) : exit(errno ? errno : -1);
}
EOM
}

sub DEFINE {
    my ($def, $val) = @_;
    my $define = defined $val ? "$def=$val" : $def ;
    unless ($DEFINE =~ /(?:^| )-D\Q$define\E(?: |$)/) {
	$DEFINE .= " -D$define";
    }
}

sub init {
    my $hints = File::Spec->catfile("hints", "$^O.pl");
    if (-f $hints) {
	print "Using hints $hints...\n";
	local $self;
	do $hints;
	if (exists $self->{LIBS}) {
	    $LIBS = $self->{LIBS};
	    print "Extra libraries: @$LIBS...\n";
	}
    }

    $DEFINE = '';

    if ($Config{d_syscall}) {
	print "Have syscall()... looking for syscall.h... ";
	if (has_include('syscall.h')) {
	    $SYSCALL_H = 'syscall.h';
	} elsif (has_include('sys/syscall.h')) {
	    $SYSCALL_H = 'sys/syscall.h';
	}
    } else {
	print "No syscall()...\n";
    }

    if ($Config{d_syscall}) {
	if (defined $SYSCALL_H) {
	    print "found <$SYSCALL_H>.\n";
	} else {
	    print "NOT found.\n";
	}
    }

    print "Looking for gettimeofday()... ";
    my $has_gettimeofday;
    if (exists $Config{d_gettimeod}) {
	$has_gettimeofday++ if $Config{d_gettimeod};
    } elsif (has_gettimeofday()) {
	$DEFINE .= ' -DHAS_GETTIMEOFDAY';
	$has_gettimeofday++;
    }

    if ($has_gettimeofday) {
	print "found.\n";
    } else {
	die <<EOD
Your operating system does not seem to have the gettimeofday() function.
(or, at least, I cannot find it)

There is no way Time::HiRes is going to work.

I am awfully sorry but I cannot go further.

Aborting configuration.

EOD
    }

    print "Looking for setitimer()... ";
    my $has_setitimer;
    if (exists $Config{d_setitimer}) {
        $has_setitimer++ if $Config{d_setitimer};
    } elsif (has_x("setitimer(ITIMER_REAL, 0, 0)")) {
        $has_setitimer++;
        $DEFINE .= ' -DHAS_SETITIMER';
    }

    if ($has_setitimer) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    print "Looking for getitimer()... ";
    my $has_getitimer;
    if (exists $Config{'d_getitimer'}) {
        $has_getitimer++ if $Config{'d_getitimer'};
    } elsif (has_x("getitimer(ITIMER_REAL, 0)")) {
        $has_getitimer++;
        $DEFINE .= ' -DHAS_GETITIMER';
    }

    if ($has_getitimer) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    if ($has_setitimer && $has_getitimer) {
	print "You have interval timers (both setitimer and getitimer).\n";
    } else {
	print "You do not have interval timers.\n";
    }

    print "Looking for ualarm()... ";
    my $has_ualarm;
    if (exists $Config{d_ualarm}) {
        $has_ualarm++ if $Config{d_ualarm};
    } elsif (has_x ("ualarm (0, 0)")) {
        $has_ualarm++;
	$DEFINE .= ' -DHAS_UALARM';
    }

    if ($has_ualarm) {
        print "found.\n";
    } else {
	print "NOT found.\n";
	if ($has_setitimer) {
	    print "But you have setitimer().\n";
	    print "We can make a Time::HiRes::ualarm().\n";
	}
    }

    print "Looking for usleep()... ";
    my $has_usleep;
    if (exists $Config{d_usleep}) {
	$has_usleep++ if $Config{d_usleep};
    } elsif (has_x ("usleep (0)")) {
	$has_usleep++;
	$DEFINE .= ' -DHAS_USLEEP';
    }

    if ($has_usleep) {
	print "found.\n";
    } else {
	print "NOT found.\n";
        print "Let's see if you have select()... ";
        if ($Config{'d_select'}) {
	    print "found.\n";
	    print "We can make a Time::HiRes::usleep().\n";
	} else {
	    print "NOT found.\n";
	    print "You won't have a Time::HiRes::usleep().\n";
	}
    }

    print "Looking for nanosleep()... ";
    my $has_nanosleep;
    if ($ENV{FORCE_NANOSLEEP_SCAN}) {
	print "forced scan... ";
	if (has_nanosleep()) {
	    $has_nanosleep++;
	    $DEFINE .= ' -DTIME_HIRES_NANOSLEEP';
	}
    }
    elsif (exists $Config{d_nanosleep}) {
	print "believing \$Config{d_nanosleep}... ";
	if ($Config{d_nanosleep}) {
	    $has_nanosleep++;
	    $DEFINE .= ' -DTIME_HIRES_NANOSLEEP';
	}
    } elsif ($^O =~ /^(mpeix)$/) {
	# MPE/iX falsely finds nanosleep from its libc equivalent.
	print "skipping because in $^O... ";
    } else {
	if (has_nanosleep()) {
	    $has_nanosleep++;
	    $DEFINE .= ' -DTIME_HIRES_NANOSLEEP';
	}
    }

    if ($has_nanosleep) {
	print "found.\n";
        print "You can mix subsecond sleeps with signals, if you want to.\n";
        print "(It's still not portable, though.)\n";
    } else {
	print "NOT found.\n";
	my $nt = ($^O eq 'os2' ? '' : 'not');
        print "You can$nt mix subsecond sleeps with signals.\n";
        print "(It would not be portable anyway.)\n";
    }

    print "Looking for clock_gettime()... ";
    my $has_clock_gettime;
    if (exists $Config{d_clock_gettime}) {
        $has_clock_gettime++ if $Config{d_clock_gettime}; # Unlikely...
    } elsif (has_clock_xxx('gettime')) {
        $has_clock_gettime++;
	$DEFINE .= ' -DTIME_HIRES_CLOCK_GETTIME';
    } elsif (defined $SYSCALL_H && has_clock_xxx_syscall('gettime')) {
        $has_clock_gettime++;
	$DEFINE .= ' -DTIME_HIRES_CLOCK_GETTIME -DTIME_HIRES_CLOCK_GETTIME_SYSCALL';
    }

    if ($has_clock_gettime) {
        if ($DEFINE =~ /-DTIME_HIRES_CLOCK_GETTIME_SYSCALL/) {
	    print "found (via syscall).\n";
	} else {
	    print "found.\n";
	}
    } else {
	print "NOT found.\n";
    }

    print "Looking for clock_getres()... ";
    my $has_clock_getres;
    if (exists $Config{d_clock_getres}) {
        $has_clock_getres++ if $Config{d_clock_getres}; # Unlikely...
    } elsif (has_clock_xxx('getres')) {
        $has_clock_getres++;
	$DEFINE .= ' -DTIME_HIRES_CLOCK_GETRES';
    } elsif (defined $SYSCALL_H && has_clock_xxx_syscall('getres')) {
        $has_clock_getres++;
	$DEFINE .= ' -DTIME_HIRES_CLOCK_GETRES -DTIME_HIRES_CLOCK_GETRES_SYSCALL';
    }

    if ($has_clock_getres) {
        if ($DEFINE =~ /-DTIME_HIRES_CLOCK_GETRES_SYSCALL/) {
	    print "found (via syscall).\n";
	} else {
	    print "found.\n";
	}
    } else {
	print "NOT found.\n";
    }

    print "Looking for clock_nanosleep()... ";
    my $has_clock_nanosleep;
    if (exists $Config{d_clock_nanosleep}) {
        $has_clock_nanosleep++ if $Config{d_clock_nanosleep}; # Unlikely...
    } elsif (has_clock_nanosleep()) {
        $has_clock_nanosleep++;
	$DEFINE .= ' -DTIME_HIRES_CLOCK_NANOSLEEP';
    }

    if ($has_clock_nanosleep) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    print "Looking for clock()... ";
    my $has_clock;
    if (exists $Config{d_clock}) {
        $has_clock++ if $Config{d_clock}; # Unlikely...
    } elsif (has_clock()) {
        $has_clock++;
	$DEFINE .= ' -DTIME_HIRES_CLOCK';
    }

    if ($has_clock) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    print "Looking for stat() subsecond timestamps...\n";

    print "Trying struct stat st_atimespec.tv_nsec...";
    my $has_stat_st_xtimespec;
    if (try_compile_and_link(<<EOM)) {
$TIME_HEADERS
#include <sys/stat.h>
int main(int argc, char** argv) {
    struct stat st;
    st.st_atimespec.tv_nsec = 0;
}
EOM
      $has_stat_st_xtimespec++;
      DEFINE('TIME_HIRES_STAT', 1);
    }

    if ($has_stat_st_xtimespec) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    print "Trying struct stat st_atimensec...";
    my $has_stat_st_xtimensec;
    if (try_compile_and_link(<<EOM)) {
$TIME_HEADERS
#include <sys/stat.h>
int main(int argc, char** argv) {
    struct stat st;
    st.st_atimensec = 0;
}
EOM
      $has_stat_st_xtimensec++;
      DEFINE('TIME_HIRES_STAT', 2);
    }

    if ($has_stat_st_xtimensec) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    print "Trying struct stat st_atime_n...";
    my $has_stat_st_xtime_n;
    if (try_compile_and_link(<<EOM)) {
$TIME_HEADERS
#include <sys/stat.h>
int main(int argc, char** argv) {
    struct stat st;
    st.st_atime_n = 0;
}
EOM
      $has_stat_st_xtime_n++;
      DEFINE('TIME_HIRES_STAT', 3);
    }

    if ($has_stat_st_xtime_n) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    print "Trying struct stat st_atim.tv_nsec...";
    my $has_stat_st_xtim;
    if (try_compile_and_link(<<EOM)) {
$TIME_HEADERS
#include <sys/stat.h>
int main(int argc, char** argv) {
    struct stat st;
    st.st_atim.tv_nsec = 0;
}
EOM
      $has_stat_st_xtim++;
      DEFINE('TIME_HIRES_STAT', 4);
    }

    if ($has_stat_st_xtim) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

    print "Trying struct stat st_uatime...";
    my $has_stat_st_uxtime;
    if (try_compile_and_link(<<EOM)) {
$TIME_HEADERS
#include <sys/stat.h>
int main(int argc, char** argv) {
    struct stat st;
    st.st_uatime = 0;
}
EOM
      $has_stat_st_uxtime++;
      DEFINE('TIME_HIRES_STAT', 5);
    }

    if ($has_stat_st_uxtime) {
        print "found.\n";
    } else {
	print "NOT found.\n";
    }

   if ($DEFINE =~ /-DTIME_HIRES_STAT=\d+/) {
    print "You seem to have stat() subsecond timestamps.\n";
    print "(Your struct stat has them, but the filesystems must help.)\n";
   } else {
    print "You do not seem to have stat subsecond timestamps.\n";
   }

    my $has_w32api_windows_h;

    if ($^O eq 'cygwin') {
        print "Looking for <w32api/windows.h>... ";
        if (has_include('w32api/windows.h')) {
	    $has_w32api_windows_h++;
	    DEFINE('HAS_W32API_WINDOWS_H');
	}
        if ($has_w32api_windows_h) {
	    print "found.\n";
	} else {
	    print "NOT found.\n";
	}
    }

    if ($DEFINE) {
        $DEFINE =~ s/^\s+//;
        if (open(XDEFINE, ">xdefine")) {
	    print XDEFINE $DEFINE, "\n";
	    close(XDEFINE);
        }
    }
}

sub doMakefile {
    my @makefileopts = ();

    if ($] >= 5.005) {
	push (@makefileopts,
	    'AUTHOR'    => 'Jarkko Hietaniemi <jhi@iki.fi>',
	    'ABSTRACT_FROM' => 'HiRes.pm',
	);
	DEFINE('ATLEASTFIVEOHOHFIVE');
    }

    push (@makefileopts,
	'NAME'	=> 'Time::HiRes',
	'VERSION_FROM' => 'HiRes.pm', # finds $VERSION
	'LIBS'	=> $LIBS,   # e.g., '-lm'
	'DEFINE'	=> $DEFINE,     # e.g., '-DHAS_SOMETHING'
	'XSOPT'	=> $XSOPT,
	  # Do not even think about 'INC' => '-I/usr/ucbinclude',
	  # Solaris will avenge.
	'INC'	=> '',     # e.g., '-I/usr/include/other'
	'INSTALLDIRS' => ($] >= 5.008 ? 'perl' : 'site'),
	'dist'      => {
	    'CI'       => 'ci -l',
	    'COMPRESS' => 'gzip -9f',
	    'SUFFIX'   => 'gz',
	},
        clean => { FILES => "xdefine" },
        realclean => { FILES=> 'const-c.inc const-xs.inc' },
    );

    if ($ENV{PERL_CORE}) {
	push @makefileopts, MAN3PODS => {};
    }

    WriteMakefile(@makefileopts);
}

sub doConstants {
    if (eval {require ExtUtils::Constant; 1}) {
	my @names = qw(CLOCK_HIGHRES CLOCK_MONOTONIC
		       CLOCK_PROCESS_CPUTIME_ID
		       CLOCK_REALTIME
		       CLOCK_SOFTTIME
		       CLOCK_THREAD_CPUTIME_ID
		       CLOCK_TIMEOFDAY
		       CLOCKS_PER_SEC
		       ITIMER_REAL ITIMER_VIRTUAL ITIMER_PROF
		       ITIMER_REALPROF
		       TIMER_ABSTIME);
	foreach (qw (d_usleep d_ualarm d_gettimeofday d_getitimer d_setitimer
		     d_nanosleep d_clock_gettime d_clock_getres
		     d_clock d_clock_nanosleep d_hires_stat)) {
	    my $macro = $_;
	    if ($macro =~ /^(d_nanosleep|d_clock_gettime|d_clock_getres|d_clock|d_clock_nanosleep)$/) {
		$macro =~ s/^d_(.+)/TIME_HIRES_\U$1/;
	    } elsif ($macro =~ /^(d_hires_stat)$/) {
		my $d_hires_stat = 0;
		$d_hires_stat = $1 if ($DEFINE =~ /-DTIME_HIRES_STAT=(\d+)/);
		push @names, {name => $_, macro => "TIME_HIRES_STAT", value => $d_hires_stat,
			      default => ["IV", "0"]};
		next;
	    } else {
		$macro =~ s/^d_(.+)/HAS_\U$1/;
	    }
	    push @names, {name => $_, macro => $macro, value => 1,
			  default => ["IV", "0"]};
	}
	ExtUtils::Constant::WriteConstants(
					   NAME => 'Time::HiRes',
					   NAMES => \@names,
					  );
    } else {
        my $file;
	foreach $file ('const-c.inc', 'const-xs.inc') {
	    my $fallback = File::Spec->catfile('fallback', $file);
	    local $/;
	    open IN, "<$fallback" or die "Can't open $fallback: $!";
	    open OUT, ">$file" or die "Can't open $file: $!";
	    print OUT <IN> or die $!;
	    close OUT or die "Can't close $file: $!";
	    close IN or die "Can't close $fallback: $!";
	}
    }
}

sub main {
    print "Configuring Time::HiRes...\n";
    if ($] == 5.007002) {
	die "Cannot Configure Time::HiRes for Perl $], aborting.\n";
    }

    if ($^O =~ /Win32/i) {
      DEFINE('SELECT_IS_BROKEN');
      $LIBS = [];
      print "System is $^O, skipping full configure...\n";
    } else {
      init();
    }
    doMakefile;
    doConstants;
    my $make = $Config{'make'} || "make";
    unless (exists $ENV{PERL_CORE} && $ENV{PERL_CORE}) {
	print  <<EOM;
Now you may issue '$make'.  Do not forget also '$make test'.
EOM
       if ((exists $ENV{LC_ALL}   && $ENV{LC_ALL}   =~ /utf-?8/i) ||
           (exists $ENV{LC_CTYPE} && $ENV{LC_CTYPE} =~ /utf-?8/i) ||
           (exists $ENV{LANG}     && $ENV{LANG}     =~ /utf-?8/i)) {
            print  <<EOM;
NOTE: if you get an error like this (the Makefile line number may vary):
Makefile:91: *** missing separator
then set the environment variable LC_ALL to "C" and retry
from scratch (re-run perl "Makefile.PL").
(And consider upgrading your Perl.)
EOM
        }
    }
}

&main;

# EOF
