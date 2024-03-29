#testing init_and_watch
#special problem with init_and_watch,
#fixed in Logger::reset by setting logger level to OFF

use Test::More;

use warnings;
use strict;

use Log::Log4perl qw(:easy);
use Log::Log4perl::Appender::TestBuffer;
use File::Spec;

my $WORK_DIR = "tmp";
if(-d "t") {
    $WORK_DIR = "t/tmp";
}
unless (-e "$WORK_DIR"){
    mkdir("$WORK_DIR", 0755) || die "can't create $WORK_DIR ($!)";
}

my $testconf= "$WORK_DIR/test27.conf";
unlink $testconf if (-e $testconf);

#goto NEW;
Log::Log4perl::Appender::TestBuffer->reset();

my $conf1 = <<EOL;
log4j.category   = WARN, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::TestBuffer
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout

log4j.category.animal.dog = DEBUG, goneAppender

log4j.appender.goneAppender          = Log::Log4perl::Appender::TestBuffer
log4j.appender.goneAppender.layout   = Log::Log4perl::Layout::SimpleLayout

log4j.category.animal.cat = INFO, myAppender

EOL
open (CONF, ">$testconf") || die "can't open $testconf $!";
print CONF $conf1;
close CONF;


Log::Log4perl->init_and_watch($testconf, 1);

my $logger = Log::Log4perl::get_logger('animal.dog');

ok(  $logger->is_debug(), "is_debug - true");
ok(  $logger->is_info(),  "is_info - true");
ok(  $logger->is_warn(),  "is_warn - true");
ok(  $logger->is_error(), "is_error - true");
ok(  $logger->is_fatal(), "is_fatal - true");

my $app0 = Log::Log4perl::Appender::TestBuffer->by_name("myAppender");

$logger->debug('debug message, should appear');

is($app0->buffer(), "DEBUG - debug message, should appear\n");


#---------------------------
#now go to sleep and reload

print "sleeping for 3 seconds\n";
sleep 3;

$conf1 = <<EOL;
log4j.category   = WARN, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::TestBuffer
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout

#*****log4j.category.animal.dog = DEBUG, goneAppender

#*****log4j.appender.goneAppender          = Log::Log4perl::Appender::TestBuffer
#*****log4j.appender.goneAppender.layout   = Log::Log4perl::Layout::SimpleLayout

log4j.category.animal.cat = INFO, myAppender

EOL
open (CONF, ">$testconf") || die "can't open $testconf $!";
print CONF $conf1;
close CONF;

ok(! $logger->is_debug(), "is_debug - false");
ok(! $logger->is_info(),  "is_info - false");
ok(  $logger->is_warn(),  "is_warn - true");
ok(  $logger->is_error(), "is_error - true");
ok(  $logger->is_fatal(), "is_fatal - true");

#now the logger is ruled by root/s WARN level
$logger->debug('debug message, should NOT appear');

my $app1 = Log::Log4perl::Appender::TestBuffer->by_name("myAppender");

is($app1->buffer(), "", "buffer empty");

$logger->warn('warning message, should appear');

is($app1->buffer(), "WARN - warning message, should appear\n", "warn in");

#check the root logger
$logger = Log::Log4perl::get_logger();

$logger->warn('warning message, should appear');

like($app1->buffer(), qr/(WARN - warning message, should appear\n){2}/,
     "2nd warn in");

# -------------------------------------------
#double-check an unrelated category with a lower level
$logger = Log::Log4perl::get_logger('animal.cat');
$logger->info('warning message to cat, should appear');

like($app1->buffer(), qr/(WARN - warning message, should appear\n){2}INFO - warning message to cat, should appear/, "message output");

NEW:
############################################################################
# This was a bug in L4p 1.01: After init_and_watch() caused a re-init,
# filename/linenumber were referring to 'eval', not the actual file
# name/line number of the message.

conf_file_write();
Log::Log4perl->init_and_watch($testconf, 1);


DEBUG("first");
  my $buf = Log::Log4perl::Appender::TestBuffer->by_name("Testbuffer");
  like($buf->buffer(), qr/027Watch2.t 130> first/, 
       "init-and-watch caller level");
  $buf->buffer("");

conf_file_write();
sleep(1);
DEBUG("second");
  $buf = Log::Log4perl::Appender::TestBuffer->by_name("Testbuffer");
  like($buf->buffer(), qr/027Watch2.t 138> second/,
       "init-and-watch caller level");
  $buf->buffer("");

conf_file_write();
sleep(1);
DEBUG("third");
  $buf = Log::Log4perl::Appender::TestBuffer->by_name("Testbuffer");
  like($buf->buffer(), qr/027Watch2.t 146> third/,
       "init-and-watch caller level");
  $buf->buffer("");

DEBUG("fourth");
  $buf = Log::Log4perl::Appender::TestBuffer->by_name("Testbuffer");
  like($buf->buffer(), qr/027Watch2.t 152> fourth/,
       "init-and-watch caller level");
  $buf->buffer("");

###########################################
sub conf_file_write {
###########################################
    open FILE, ">$testconf" or die $!;
    print FILE <<EOT;
log4perl.category.main = DEBUG, Testbuffer
log4perl.appender.Testbuffer        = Log::Log4perl::Appender::TestBuffer
log4perl.appender.Testbuffer.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.Testbuffer.layout.ConversionPattern = %d %F{1} %L> %m %n
EOT
    close FILE;
}

BEGIN {plan tests => 19};
unlink $testconf;
